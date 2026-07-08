/* api_test.js — exercises the server against a SANDBOX game root and an isolated tool
 * workspace (snapshots/settings), so a test run can never touch the real repo.
 * The model under test: the tool edits REAL game data files (entry-centric /api/game/*),
 * `enabled: false` is the kill-switch, art deploys on a new entry's first Save or via the
 * explicit /api/art/deploy (never straight from generation). Run: node test/api_test.js */
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const TOOL = path.resolve(__dirname, '..');
const SANDBOX = fs.mkdtempSync(path.join(os.tmpdir(), 'cardgame-sandbox-'));
const WS_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'cardgame-toolws-'));
const PORT = 8477;
const BASE = `http://127.0.0.1:${PORT}`;

for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map', 'assets/cards/enemies', 'assets/relics', 'assets/abilities'])
  fs.mkdirSync(path.join(SANDBOX, d), { recursive: true });
fs.writeFileSync(path.join(SANDBOX, 'data/cards/base.json'), JSON.stringify([
  { id: 'pawn', display_name: 'Pawn', cost: 1, attack: 1, health: 2, speed: 3, chess_pieces: ['pawn'] },
  { id: 'goblin_cutter', display_name: 'Goblin Cutter', cost: 1, attack: 2, health: 1, speed: 4, enemy_only: true },
]));
fs.writeFileSync(path.join(SANDBOX, 'data/statuses/poison.json'),
  JSON.stringify({ id: 'poison', display_name: 'Poison' }));

let failures = 0;
function check(name, cond, extra) {
  if (cond) console.log('  ok  ' + name);
  else { failures++; console.log('FAIL  ' + name + (extra ? ' — ' + extra : '')); }
}
async function api(p, body) {
  const res = await fetch(BASE + p, body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  return { status: res.status, data };
}
const readSbox = rel => JSON.parse(fs.readFileSync(path.join(SANDBOX, rel), 'utf8'));

async function main() {
  const server = spawn(process.execPath, [path.join(TOOL, 'server.js'), String(PORT)], {
    env: Object.assign({}, process.env, { CARDGAME_ROOT: SANDBOX, CARDGAME_WORKSPACE: WS_DIR,
      // cloud-provider tests: both SDKs honor their BASE_URL env vars, so the fakes below
      // stand in for api.anthropic.com / api.openai.com without touching adapter code
      ANTHROPIC_API_KEY: 'test-key', ANTHROPIC_BASE_URL: 'http://127.0.0.1:8483',
      OPENAI_API_KEY: 'test-key', OPENAI_BASE_URL: 'http://127.0.0.1:8484/v1',
      // claude-code provider tests: the stub CLI logs its invocation + replies from a file
      FAKE_CLAUDE_LOG: path.join(WS_DIR, 'fake_claude_log.json'),
      FAKE_CLAUDE_REPLY_FILE: path.join(WS_DIR, 'fake_claude_reply.txt') }),
    stdio: 'inherit',
  });
  await new Promise(r => setTimeout(r, 700));

  try {
    // ── state: the game tree is the list ──
    let r = await api('/api/state');
    check('GET /api/state 200', r.status === 200);
    check('game tree lists entries with files', r.data.game.card.some(c => c.id === 'pawn' && c.file === 'base.json'));
    check('vocab exposes builder vocabularies', Array.isArray(r.data.vocab.simpleEvents) && Array.isArray(r.data.vocab.targetKinds));

    // ── save NEW entries into a chosen (fresh) file ──
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_zap', display_name: 'Zap', cost: 1, attack: 2, health: 2, speed: 3,
      effects: [{ trigger: { kind: 'dual_event', event: 'attack', origin_conditions: [{ relation: 'self' }] },
        targets: { kind: 'participant', participant: 'destination' }, status: { id: 'poison', stacks: 1 } }] } });
    check('new entry saved into a new file', r.status === 200 && r.data.action === 'added', JSON.stringify(r.data));
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_bolt', display_name: 'Bolt', cost: 1, attack: 3, health: 1, speed: 5 } });
    check('second entry appends to the same file', r.data.action === 'added');
    let file = readSbox('data/cards/apitest_units.json');
    check('file holds both entries', Array.isArray(file) && file.length === 2 && file[1].id === 'apitest_bolt');

    // ── updating an existing entry ignores the file argument (one home per id) ──
    r = await api('/api/game/save', { type: 'card', file: 'somewhere_else.json', data: {
      id: 'apitest_zap', display_name: 'Zap', cost: 1, attack: 9, health: 2, speed: 3 } });
    check('existing entry updates in place', r.data.action === 'updated' && r.data.file === 'data/cards/apitest_units.json');
    check('update landed', readSbox('data/cards/apitest_units.json')[0].attack === 9);
    check('no stray file created', !fs.existsSync(path.join(SANDBOX, 'data/cards/somewhere_else.json')));

    // ── the enabled kill-switch is just data ──
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_bolt', display_name: 'Bolt', cost: 1, attack: 3, health: 1, speed: 5, enabled: false } });
    check('disable saves', r.status === 200);
    check('enabled:false persisted', readSbox('data/cards/apitest_units.json')[1].enabled === false);

    // ── validation still gates saves ──
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_bad', display_name: 'B', cost: 1, attack: 1, health: 1, speed: 1,
      effects: [{ trigger: { kind: 'event', event: 'bogus_event' }, targets: { kind: 'all' }, attribute: 'attack', amount: 1 }] } });
    check('invalid entry rejected', r.status === 400 && /not a simple event/.test(r.data.error), r.data.error);

    // ── revert semantics: replaced → original; added → removed ──
    r = await api('/api/game/item?type=card&id=pawn');
    await api('/api/game/save', { type: 'card', file: 'base.json', data: Object.assign({}, r.data.data, { attack: 7 }) });
    check('game-native entry edited', readSbox('data/cards/base.json')[0].attack === 7);
    await api('/api/game/restore', { type: 'card', id: 'pawn' });
    check('revert restores the original', readSbox('data/cards/base.json')[0].attack === 1);
    await api('/api/game/restore', { type: 'card', id: 'apitest_bolt' });
    file = readSbox('data/cards/apitest_units.json');
    check('reverting an ADDED entry removes it', file.length === 1 && file[0].id === 'apitest_zap');

    // ── delete + revert-deleted ──
    r = await api('/api/game/delete-entry', { type: 'card', id: 'apitest_zap' });
    check('delete empties and removes the file', r.status === 200 && r.data.removedFile === true
      && !fs.existsSync(path.join(SANDBOX, 'data/cards/apitest_units.json')));
    await api('/api/game/restore', { type: 'card', id: 'apitest_zap' });
    check('reverting a DELETE re-adds the entry', fs.existsSync(path.join(SANDBOX, 'data/cards/apitest_units.json'))
      && readSbox('data/cards/apitest_units.json')[0].id === 'apitest_zap');
    await api('/api/game/delete-entry', { type: 'card', id: 'apitest_zap' });

    // ── art auto-deploys with Save (workspace png pending → assets on save) ──
    const PNG1x1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
    fs.mkdirSync(path.join(WS_DIR, 'art', 'card'), { recursive: true });
    fs.writeFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_arty.png'), PNG1x1);
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_arty', display_name: 'Arty', cost: 1, attack: 1, health: 1, speed: 1 } });
    check('pending art deploys on save', r.data.art === 'assets/cards/apitest_arty.png'
      && fs.existsSync(path.join(SANDBOX, 'assets/cards/apitest_arty.png')));
    // enemy cards route their art to enemies/
    fs.writeFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_rat.png'), PNG1x1);
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_rat', display_name: 'Rat', cost: 1, attack: 1, health: 1, speed: 1, enemy_only: true } });
    check('enemy art routes to enemies/', r.data.art === 'assets/cards/enemies/apitest_rat.png'
      && fs.existsSync(path.join(SANDBOX, 'assets/cards/enemies/apitest_rat.png')));
    // ── explicit deploy: regenerated art for an EXISTING entry only lands on request ──
    fs.writeFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_arty.png'), PNG1x1);
    r = await api('/api/art/deploy', { type: 'card', id: 'apitest_arty' });
    check('explicit art deploy works', r.data.ok && r.data.art === 'assets/cards/apitest_arty.png');
    r = await api('/api/art/deploy', { type: 'card', id: 'apitest_nonexistent' });
    check('deploy without workspace art rejected', r.status === 400);
    // status art has a REAL game slot: StatusData.icon() reads assets/ui/status/<id>_status.png
    fs.mkdirSync(path.join(WS_DIR, 'art', 'status'), { recursive: true });
    fs.writeFileSync(path.join(WS_DIR, 'art', 'status', 'poison.png'), PNG1x1);
    r = await api('/api/art/deploy', { type: 'status', id: 'poison' });
    check('status art deploys to the pip icon convention',
      r.status === 200 && r.data.art === 'assets/ui/status/poison_status.png'
      && fs.existsSync(path.join(SANDBOX, 'assets/ui/status/poison_status.png')), JSON.stringify(r.data));
    // upgrade trees carry an emblem slot too (assets/ui/upgrades/<id>.png, plain name)
    fs.writeFileSync(path.join(SANDBOX, 'data/upgrades/apitest_tree.json'),
      JSON.stringify({ id: 'apitest_tree', display_name: 'T', nodes: [{ id: 'n1', display_name: 'N', effects: [] }] }));
    fs.mkdirSync(path.join(WS_DIR, 'art', 'upgrade'), { recursive: true });
    fs.writeFileSync(path.join(WS_DIR, 'art', 'upgrade', 'apitest_tree.png'), PNG1x1);
    r = await api('/api/art/deploy', { type: 'upgrade', id: 'apitest_tree' });
    check('upgrade emblem deploys to assets/ui/upgrades',
      r.status === 200 && r.data.art === 'assets/ui/upgrades/apitest_tree.png'
      && fs.existsSync(path.join(SANDBOX, 'assets/ui/upgrades/apitest_tree.png')), JSON.stringify(r.data));
    await api('/api/game/delete-entry', { type: 'card', id: 'apitest_arty' });
    await api('/api/game/delete-entry', { type: 'card', id: 'apitest_rat' });

    // ── external reference upload ──
    r = await api('/api/art/upload-ref', { name: 'my ref!.png', dataBase64: PNG1x1.toString('base64') });
    check('reference upload stores a sanitized name', r.data.ok && r.data.name === 'my_ref_.png'
      && fs.existsSync(path.join(WS_DIR, 'refs', 'my_ref_.png')));
    // generating with an uploaded ref must NOT demand the item's own current art
    r = await api('/api/art/generate', { type: 'card', id: 'apitest_noart', prompt: 'x',
      useRef: true, refUpload: 'my_ref_.png', model: 'krea2', refMode: 'img2img', denoise: 0.6 });
    check('uploaded ref bypasses the current-art requirement',
      (r.data.error || '') !== 'this item has no current art to use as input',
      r.data.error);

    // ── client-side pixel edits (flip) write back through /api/art/put ──
    r = await api('/api/art/put', { type: 'card', id: 'apitest_flip', dataBase64: PNG1x1.toString('base64') });
    check('art put stores workspace art', r.data.ok
      && fs.readFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_flip.png')).equals(PNG1x1));

    // ── reference catalog: composition-affinity ranking for the advanced browser ──
    // Query composition: darkness_water_bishop_queen. Expected tiers:
    //   0: bishop_queen (bare piece version)  1: subsets by score  2: foreign components
    const rankCards = [
      { id: 'bishop_queen', chess_pieces: ['bishop', 'queen'] },
      { id: 'darkness_bishop_queen', elements: ['darkness'], chess_pieces: ['bishop', 'queen'] },
      { id: 'darkness_water_queen', elements: ['darkness', 'water'], chess_pieces: ['queen'] },
      { id: 'lone_queen', chess_pieces: ['queen'] },
      { id: 'darkness_water_pawn', elements: ['darkness', 'water'], chess_pieces: ['pawn'] },
      { id: 'artless_bishop_queen', chess_pieces: ['bishop', 'queen'] },   // no art → excluded
    ];
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/rank_units.json'), JSON.stringify(
      rankCards.map(c => Object.assign({ display_name: c.id, cost: 1, attack: 1, health: 1, speed: 1 }, c))));
    for (const c of rankCards) if (c.id !== 'artless_bishop_queen')
      fs.writeFileSync(path.join(SANDBOX, 'assets/cards', c.id + '.png'), PNG1x1);
    r = await api('/api/art/references', {
      elements: ['darkness', 'water'], chess_pieces: ['bishop', 'queen'], excludeId: 'zzz' });
    const order = r.data.refs.map(x => x.id);
    check('references ranked: bare piece version first', order[0] === 'bishop_queen', order.join(','));
    check('references ranked: subsets by shared score', order[1] === 'darkness_bishop_queen'
      && order[2] === 'darkness_water_queen' && order[3] === 'lone_queen', order.join(','));
    check('references ranked: foreign components trail, artless excluded',
      order.indexOf('darkness_water_pawn') > order.indexOf('lone_queen')
      && !order.includes('artless_bishop_queen'), order.join(','));
    check('reference entries carry art + composition', r.data.refs[0].art === 'assets/cards/bishop_queen.png'
      && JSON.stringify(r.data.refs[0].chess_pieces) === '["bishop","queen"]');
    // enemy cards are flagged so the browser can filter them
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/enemies/goblin_cutter.png'), PNG1x1);
    r = await api('/api/art/references', { elements: [], chess_pieces: [], excludeId: 'zzz' });
    const goblin = r.data.refs.find(x => x.id === 'goblin_cutter');
    check('reference entries carry the enemy flag', goblin && goblin.enemy === true
      && r.data.refs.find(x => x.id === 'bishop_queen').enemy === false);

    // ── game art as the image-model reference ──
    r = await api('/api/art/generate', { type: 'card', id: 'apitest_noart2', prompt: 'x',
      useRef: true, refGameArt: 'assets/cards/bishop_queen.png', model: 'krea2', refMode: 'img2img' });
    check('game-art ref bypasses the current-art requirement',
      (r.data.error || '') !== 'this item has no current art to use as input', r.data.error);
    r = await api('/api/art/generate', { type: 'card', id: 'apitest_noart2', prompt: 'x',
      useRef: true, refGameArt: '../secrets.png', model: 'krea2', refMode: 'img2img' });
    check('game-art ref path is validated', /reference game art not found/.test(r.data.error || ''), r.data.error);

    // ── LLM art prompts: a fake Ollama proves the request shape + response cleanup ──
    let llmReq = null;
    const fakeOllama = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        llmReq = { path: rq.url, body: JSON.parse(b) };
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ response: '<think>hmm</think>\nPrompt: "a spectral pawn knight wreathed in venom mist,\npainterly"' }));
      });
    });
    await new Promise(ok => fakeOllama.listen(8479, ok));
    await api('/api/settings', { ollamaUrl: 'http://127.0.0.1:8479', llmModel: 'testmodel' });
    r = await api('/api/art/prompt', { type: 'card', name: 'Pawn',
      summary: ['Pawn — Unit (pawn).', 'Cost 1 · ATK 1 · HP 2 · SPD 3.'], example: 'example staging' });
    check('llm prompt returns cleaned text',
      r.data.ok && r.data.prompt === 'a spectral pawn knight wreathed in venom mist, painterly', JSON.stringify(r.data));
    check('llm request carries model, rules and item data',
      llmReq && llmReq.path === '/api/generate' && llmReq.body.model === 'testmodel'
      && llmReq.body.stream === false && /never use the words/i.test(llmReq.body.system)
      && llmReq.body.prompt.includes('Cost 1') && llmReq.body.prompt.includes('example staging'));
    check('text-only llm request has no images', llmReq.body.images === undefined);
    // visual references ride along as base64 images + the style-matching addendum
    r = await api('/api/art/prompt', { type: 'card', name: 'Pawn', summary: [],
      refArts: ['assets/cards/bishop_queen.png', 'assets/cards/lone_queen.png'] });
    check('llm vision request carries the reference images',
      r.data.ok && llmReq.body.images && llmReq.body.images.length === 2
      && llmReq.body.images[0] === PNG1x1.toString('base64')
      && /reference illustrations/i.test(llmReq.body.system));
    // optional creative direction: concept always rides along, refHint only with refs
    r = await api('/api/art/prompt', { type: 'card', name: 'Pawn', summary: [],
      concept: 'menacing sea witch', refHint: 'copy the armor' });
    check('concept rides along, refHint dropped without refs',
      llmReq.body.prompt.includes('Concept direction (follow this): menacing sea witch')
      && !llmReq.body.prompt.includes('copy the armor'));
    r = await api('/api/art/prompt', { type: 'card', name: 'Pawn', summary: [],
      refArts: ['assets/cards/bishop_queen.png'], concept: 'menacing sea witch', refHint: 'copy the armor' });
    check('refHint included when references are attached',
      llmReq.body.prompt.includes('How to use the reference illustrations: copy the armor')
      && llmReq.body.prompt.includes('menacing sea witch'));
    r = await api('/api/art/prompt', { type: 'card', name: 'Pawn', summary: [],
      refArts: ['../oops.png'] });
    check('llm ref art path is validated', r.status === 400 && /reference art not found/.test(r.data.error || ''));
    // vision analysis of the item's CURRENT art → a recreating prompt (apitest_flip has
    // workspace art from the /api/art/put test above)
    r = await api('/api/art/prompt-from-art', { type: 'card', id: 'apitest_flip' });
    check('prompt-from-art analyzes the current art',
      r.data.ok && r.data.prompt === 'a spectral pawn knight wreathed in venom mist, painterly'
      && llmReq.body.images.length === 1 && llmReq.body.images[0] === PNG1x1.toString('base64')
      && /recreate/i.test(llmReq.body.system));
    // the ✨ guidance inputs apply here too — and refHint needs no attached refs
    // (the analyzed image IS the reference)
    r = await api('/api/art/prompt-from-art', { type: 'card', id: 'apitest_flip',
      concept: 'menacing sea witch', refHint: 'copy the armor' });
    check('prompt-from-art honors concept + refHint guidance',
      r.data.ok && llmReq.body.prompt.includes('menacing sea witch')
      && llmReq.body.prompt.includes('copy the armor'));
    r = await api('/api/art/prompt-from-art', { type: 'card', id: 'apitest_flip' });
    check('prompt-from-art without guidance stays bare',
      r.data.ok && !/Concept direction|as a reference/.test(llmReq.body.prompt));
    r = await api('/api/art/prompt-from-art', { type: 'card', id: 'apitest_no_art_at_all' });
    check('prompt-from-art without art rejected', r.status === 400 && /no current art/.test(r.data.error || ''));
    fakeOllama.close();

    // ── ✨ effects from words: generate → validate → retry, on a scripted fake ──
    const fxReqs = []; let fxQueue = [];
    const fakeFx = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        fxReqs.push(JSON.parse(b));
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ response: fxQueue.shift() || '[]' }));
      });
    });
    await new Promise(ok => fakeFx.listen(8481, ok));
    await api('/api/settings', { ollamaUrl: 'http://127.0.0.1:8481', effectsModel: 'fxmodel' });
    // an entry with a valid effect → the example miner has something to pair
    await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_fx_example', display_name: 'FxEx', cost: 1, attack: 1, health: 1, speed: 1,
      effects: [{ trigger: { kind: 'event', event: 'play', of: 'self' },
        targets: { kind: 'self' }, attribute: 'attack', amount: 2 }] } });
    const GOOD_FX = JSON.stringify([{ trigger: { kind: 'while' },
      targets: { kind: 'all', conditions: [{ composition: ['pawn'] }] }, attribute: 'attack', amount: 1 }]);
    const BAD_FX = JSON.stringify([{ trigger: { kind: 'event', event: 'bogus' },
      targets: { kind: 'all' }, attribute: 'attack', amount: 1 }]);

    fxQueue = ['<think>hm</think>```json\n' + GOOD_FX + '\n```'];
    r = await api('/api/effects/from-text', { type: 'card', text: '+1 strength to all pawn units' });
    check('effects-from-text returns validated effects (noise stripped)',
      r.data.ok && r.data.attempts === 1 && !r.data.warning
      && r.data.effects.length === 1 && r.data.effects[0].attribute === 'attack', JSON.stringify(r.data));
    let fxReq = fxReqs[fxReqs.length - 1];
    check('effects request uses the effects model + schema + the text',
      fxReq.model === 'fxmodel' && /JSON array of effect objects/.test(fxReq.system)
      && fxReq.prompt.includes('+1 strength to all pawn units'));
    check('prompt carries mined english⇒json example pairs',
      /Examples \(plain words ⇒ JSON\)/.test(fxReq.prompt) && fxReq.prompt.includes('⇒ [{'));
    check('schema prompt lists the live status vocab', /poison/.test(fxReq.system));

    fxQueue = [BAD_FX, GOOD_FX];
    r = await api('/api/effects/from-text', { type: 'card', text: 'x' });
    check('invalid attempt retries with the validator error fed back',
      r.data.attempts === 2 && !r.data.warning
      && fxReqs[fxReqs.length - 1].prompt.includes('not a simple event'), JSON.stringify(r.data));

    fxQueue = ['no json here at all', GOOD_FX];
    r = await api('/api/effects/from-text', { type: 'card', text: 'x' });
    check('unparseable reply retries', r.data.attempts === 2 && !r.data.warning, JSON.stringify(r.data));

    fxQueue = [BAD_FX, BAD_FX, BAD_FX];
    r = await api('/api/effects/from-text', { type: 'card', text: 'x' });
    check('persistent invalid returns the best attempt WITH its warning',
      r.data.ok && r.data.attempts === 3 && /not a simple event/.test(r.data.warning || '')
      && r.data.effects.length === 1, JSON.stringify(r.data));

    r = await api('/api/effects/from-text', { type: 'card', text: '   ' });
    check('empty text rejected', r.status === 400);
    await api('/api/game/delete-entry', { type: 'card', id: 'apitest_fx_example' });
    fakeFx.close();
    // point Ollama back at 8479 — the multi-image fallback tests below reuse that port
    await api('/api/settings', { ollamaUrl: 'http://127.0.0.1:8479' });

    // ── named presets for the LLM guidance inputs persist like style presets ──
    r = await api('/api/settings', { conceptPresets: { witchy: 'menacing sea witch' },
      refHintPresets: { armor: 'copy the armor design' } });
    check('llm guidance presets persist', r.data.settings.conceptPresets.witchy === 'menacing sea witch'
      && r.data.settings.refHintPresets.armor === 'copy the armor design');
    r = await api('/api/state');
    check('llm guidance presets exposed in state', r.data.settings.conceptPresets.witchy === 'menacing sea witch'
      && r.data.settings.refHintPresets.armor === 'copy the armor design');

    // ── multi-image fallback: runners like gemma4 crash on >1 images per request; the
    // server must fall back to per-image style notes + a text-only synthesis call ──
    const seenCalls = [];
    let lastCrashyBody = null;
    const crashyOllama = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        const body = JSON.parse(b);
        seenCalls.push((body.images || []).length);
        if ((body.images || []).length === 0) lastCrashyBody = body;
        rs.setHeader('Content-Type', 'application/json');
        if ((body.images || []).length > 1) { rs.statusCode = 500; rs.end(JSON.stringify({ error: 'runner crashed' })); return; }
        rs.end(JSON.stringify({ response: (body.images || []).length === 1
          ? 'painterly, glowing rim light' : 'a knight in the described painterly style' }));
      });
    });
    await new Promise(ok => crashyOllama.listen(8479, ok));
    r = await api('/api/art/prompt', { type: 'card', name: 'Knight', summary: [],
      refArts: ['assets/cards/bishop_queen.png', 'assets/cards/lone_queen.png'],
      concept: 'menacing sea witch', refHint: 'copy the armor' });
    check('multi-image crash falls back to style notes',
      r.data.ok && r.data.prompt === 'a knight in the described painterly style'
      && JSON.stringify(seenCalls) === '[2,1,1,0]', JSON.stringify({ calls: seenCalls, out: r.data }));
    check('guidance survives into the fallback synthesis call',
      lastCrashyBody && lastCrashyBody.prompt.includes('menacing sea witch')
      && lastCrashyBody.prompt.includes('copy the armor')
      && lastCrashyBody.prompt.includes('Reference style notes:'), lastCrashyBody && lastCrashyBody.prompt);
    crashyOllama.close();
    r = await api('/api/art/prompt', { type: 'card', name: 'Pawn', summary: [] });
    check('llm unreachable reports cleanly', r.status === 502 && /unreachable/i.test(r.data.error));

    // ── cloud providers: the ✨ features route to Claude / ChatGPT via the same seam ──
    let claudeReq = null, claudeText = 'Prompt: "a tidal bishop, painterly"';
    const fakeClaude = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        claudeReq = { path: rq.url, auth: String(rq.headers['x-api-key'] || rq.headers.authorization || ''), body: JSON.parse(b) };
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-test',
          content: [{ type: 'text', text: claudeText }],
          stop_reason: 'end_turn', usage: { input_tokens: 1, output_tokens: 1 } }));
      });
    });
    await new Promise(ok => fakeClaude.listen(8483, ok));
    r = await api('/api/settings', { llmProvider: 'claude', claudeModel: 'claude-test' });
    check('provider + cloud models persist in settings',
      r.data.settings.llmProvider === 'claude' && r.data.settings.claudeModel === 'claude-test');
    r = await api('/api/art/prompt', { type: 'card', name: 'Bishop', summary: ['Cost 2'],
      refArts: ['assets/cards/bishop_queen.png'] });
    check('claude provider serves ✨ art prompts (cleaned)',
      r.data.ok && r.data.prompt === 'a tidal bishop, painterly', JSON.stringify(r.data));
    check('claude request carries model, system, vision block and adaptive thinking',
      claudeReq && claudeReq.path === '/v1/messages' && claudeReq.body.model === 'claude-test'
      && /never use the words/i.test(claudeReq.body.system)
      && claudeReq.body.thinking && claudeReq.body.thinking.type === 'adaptive'
      && claudeReq.body.messages[0].content.some(c => c.type === 'image' && c.source.data === PNG1x1.toString('base64'))
      && claudeReq.body.messages[0].content.some(c => c.type === 'text' && c.text.includes('Cost 2')),
      JSON.stringify(claudeReq && claudeReq.body));
    check('claude request is authenticated', /test-key/.test(claudeReq.auth), claudeReq.auth);
    // ✨ effects ride the same switch — ONE provider model, s.effectsModel ignored
    claudeText = '```json\n' + GOOD_FX + '\n```';
    r = await api('/api/effects/from-text', { type: 'card', text: '+1 strength to all pawn units' });
    check('claude serves ✨ effects with the provider model',
      r.data.ok && !r.data.warning && r.data.effects.length === 1
      && claudeReq.body.model === 'claude-test'
      && /JSON array of effect objects/.test(claudeReq.body.system), JSON.stringify(r.data));

    let openaiReq = null;
    const fakeOpenAI = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        openaiReq = { path: rq.url, auth: String(rq.headers.authorization || ''), body: JSON.parse(b) };
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ id: 'resp_1', object: 'response', status: 'completed',
          output: [{ type: 'message', role: 'assistant',
            content: [{ type: 'output_text', text: 'a stormy rook, painterly', annotations: [] }] }],
          usage: { input_tokens: 1, output_tokens: 1 } }));
      });
    });
    await new Promise(ok => fakeOpenAI.listen(8484, ok));
    await api('/api/settings', { llmProvider: 'openai', openaiModel: 'gpt-test' });
    r = await api('/api/art/prompt', { type: 'card', name: 'Rook', summary: [],
      refArts: ['assets/cards/bishop_queen.png'] });
    check('openai provider serves ✨ art prompts',
      r.data.ok && r.data.prompt === 'a stormy rook, painterly', JSON.stringify(r.data));
    check('openai request uses the Responses API with instructions + image',
      openaiReq && openaiReq.path === '/v1/responses' && openaiReq.body.model === 'gpt-test'
      && /never use the words/i.test(openaiReq.body.instructions)
      && openaiReq.body.input[0].content.some(c => c.type === 'input_image')
      && openaiReq.auth === 'Bearer test-key', JSON.stringify(openaiReq && openaiReq.body));

    // ── claude-code provider: rides the user's subscription via `claude -p` ──
    const ccLog = path.join(WS_DIR, 'fake_claude_log.json');
    const ccReply = path.join(WS_DIR, 'fake_claude_reply.txt');
    fs.writeFileSync(ccReply, 'Prompt: "a moonlit knight, painterly"');
    await api('/api/settings', { llmProvider: 'claude-code', claudeCodeModel: 'opus',
      claudeCliCmd: `node ${path.join(TOOL, 'test', 'fake_claude.js')}` });
    r = await api('/api/art/prompt', { type: 'card', name: 'Knight', summary: ['Cost 3'],
      refArts: ['assets/cards/bishop_queen.png'] });
    check('claude-code provider serves ✨ art prompts (cleaned)',
      r.data.ok && r.data.prompt === 'a moonlit knight, painterly', JSON.stringify(r.data));
    const cc = JSON.parse(fs.readFileSync(ccLog, 'utf8'));
    check('claude-code runs headless print mode with only the Read tool',
      cc.argv.includes('-p') && cc.argv.join(' ').includes('--output-format text')
      && cc.argv.join(' ').includes('--allowedTools Read')
      && cc.argv.join(' ').includes('--model opus'), JSON.stringify(cc.argv));
    check('claude-code system prompt travels via file, not shell args',
      cc.argv.includes('--system-prompt-file') && /never use the words/i.test(cc.systemPrompt));
    check('claude-code prompt arrives on stdin with the item data',
      cc.stdin.includes('Cost 3') && /Reference image 1 .* Read tool: (.+\.png)/.test(cc.stdin));
    check('claude-code reference image written for the Read tool',
      cc.refs.length === 1 && !cc.refs[0].missing && cc.refs[0].data === PNG1x1.toString('base64'));
    // ✨ effects ride the same switch
    fs.writeFileSync(ccReply, '```json\n' + GOOD_FX + '\n```');
    r = await api('/api/effects/from-text', { type: 'card', text: '+1 strength to all pawn units' });
    check('claude-code serves ✨ effects', r.data.ok && !r.data.warning
      && r.data.effects.length === 1, JSON.stringify(r.data));

    r = await api('/api/settings', { llmProvider: 'bogus' });
    check('bad llmProvider rejected', r.status === 400);
    await api('/api/settings', { llmProvider: 'ollama' });
    fakeClaude.close(); fakeOpenAI.close();

    // ── per-entry art recipe (tool.art) rides save/update untouched ──
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_recipe', display_name: 'Rec', cost: 1, attack: 1, health: 1, speed: 1,
      tool: { art: { prompt: 'moody bishop', model: 'krea2', width: 1024, height: 1536,
        steps: 20, guidance: 4, rembg: false, ref: { source: 'game', path: 'assets/cards/bishop_queen.png' },
        concept: 'menacing sea witch',
        last: { seed: 12345, prompt: 'moody bishop', style: 'cartoon', at: '2026-07-07' } } } } });
    let recEntry = readSbox('data/cards/apitest_units.json').find(e => e.id === 'apitest_recipe');
    check('art recipe (tool.art) persists on the entry', r.status === 200
      && recEntry.tool.art.last.seed === 12345
      && recEntry.tool.art.ref.path === 'assets/cards/bishop_queen.png', JSON.stringify(recEntry));
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data:
      Object.assign({}, recEntry, { attack: 2 }) });
    recEntry = readSbox('data/cards/apitest_units.json').find(e => e.id === 'apitest_recipe');
    check('recipe survives an entry update', recEntry.attack === 2 && recEntry.tool.art.last.seed === 12345);
    await api('/api/game/delete-entry', { type: 'card', id: 'apitest_recipe' });

    // ── move-entry: relocate between files with revertible bookkeeping ──
    // (the set generator uses this to pull an existing composition into the family file)
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_move_src.json'),
      JSON.stringify([{ id: 'apitest_mover', display_name: 'Mover', cost: 1, attack: 2, health: 3, speed: 4, elements: ['air', 'earth'], chess_pieces: ['knight'] }]));
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_move_dst.json'),
      JSON.stringify([{ id: 'apitest_anchor', display_name: 'Anchor', cost: 1, attack: 1, health: 1, speed: 1 }]));
    r = await api('/api/state');
    check('game entries expose composition for set planning',
      r.data.game.card.some(c => c.id === 'apitest_mover' && c.elements.join() === 'air,earth' && c.chess_pieces.join() === 'knight'));
    r = await api('/api/game/move-entry', { type: 'card', id: 'apitest_mover', file: 'apitest_move_dst.json' });
    check('move-entry relocates the definition verbatim (emptied source removed)',
      r.status === 200 && r.data.action === 'moved'
      && !fs.existsSync(path.join(SANDBOX, 'data/cards/apitest_move_src.json'))
      && readSbox('data/cards/apitest_move_dst.json').some(e => e.id === 'apitest_mover' && e.attack === 2));
    r = await api('/api/game/move-entry', { type: 'card', id: 'apitest_anchor', file: 'apitest_move_dst.json' });
    check('move to its own file is a no-op', r.data.action === 'in_place');
    r = await api('/api/game/restore', { type: 'card', id: 'apitest_mover' });
    check('reverting a move puts the entry back in its source file',
      r.status === 200
      && readSbox('data/cards/apitest_move_src.json').some(e => e.id === 'apitest_mover' && e.attack === 2)
      && !readSbox('data/cards/apitest_move_dst.json').some(e => e.id === 'apitest_mover'));

    // ── ✨ recipe inference: concept from piece-relatives, theme from element-relatives ──
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_kin_lib.json'), JSON.stringify([
      { id: 'bishop_rook', display_name: 'Bishop Rook', cost: 2, attack: 2, health: 4, speed: 2,
        chess_pieces: ['bishop', 'rook'], tool: { art: { prompt: 'a mitred tower-warden construct' } } },
      { id: 'darkness_earth_pawn', display_name: 'Dark Earth Pawn', cost: 1, attack: 1, health: 2, speed: 3,
        elements: ['darkness', 'earth'], chess_pieces: ['pawn'] },
    ]));
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/bishop_rook.png'), PNG1x1);
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/darkness_earth_pawn.png'), PNG1x1);
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_kin.json'), JSON.stringify([
      { id: 'darkness_earth_bishop_rook', display_name: 'Grave Bastion', cost: 4, attack: 4, health: 8, speed: 1,
        elements: ['darkness', 'earth'], chess_pieces: ['bishop', 'rook'] },
      { id: 'darkness_earth_knight', display_name: 'Dark Knight', cost: 2, attack: 3, health: 3, speed: 4,
        elements: ['darkness', 'earth'], chess_pieces: ['knight'], tool: { art: { prompt: 'already authored' } } },
    ]));
    const KIN_PROMPT = 'a looming basalt bishop-tower wreathed in shadow, painterly';
    let kinReq = null;
    const fakeKin = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        kinReq = JSON.parse(b);
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ response: KIN_PROMPT }));
      });
    });
    await new Promise(ok => fakeKin.listen(8482, ok));
    await api('/api/settings', { llmProvider: 'ollama', ollamaUrl: 'http://127.0.0.1:8482' });
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook' });
    check('kin inference anchors on the bare piece version\'s IMAGE (same-concept default)',
      r.data.ok && r.data.prompt === KIN_PROMPT
      && r.data.ref && r.data.ref.path === 'assets/cards/bishop_rook.png'
      && r.data.inferredFrom.anchor === 'bishop_rook'
      && r.data.inferredFrom.theme.includes('darkness_earth_pawn')
      && r.data.stats.mode === 'concept', JSON.stringify(r.data));
    check('same-concept mode carries the DESIGN and frees the presentation',
      kinReq && kinReq.prompt.includes('Reference image 1 is THE CONCEPT')
      && /Inventory what makes the subject/.test(kinReq.prompt)
      && /Same recognizable character, new presentation/.test(kinReq.prompt)
      // relatives ride in by ANONYMOUS label — the authored prompt rides along verbatim,
      // but the composition-encoding id never appears (that was the leak)
      && /theme example \d+: "already authored"/.test(kinReq.prompt)
      && /theme example \d+: see reference image 2/.test(kinReq.prompt)
      && !/Composition:/.test(kinReq.prompt)
      && !/bishop_rook|darkness_earth/.test(kinReq.prompt)
      && (kinReq.images || []).length >= 2, kinReq && kinReq.prompt);
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'replicate' });
    check('replicate mode carries the PICTURE (re-dress only)',
      r.data.ok && r.data.stats.mode === 'replicate'
      && /re-dress it in the theme shown by the examples/.test(kinReq.prompt)
      && /SAME illustration, re-themed/.test(kinReq.prompt)
      && !/darkness and earth/.test(kinReq.prompt), kinReq && kinReq.prompt);   // no element naming
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('free adherence keeps the blend behavior (minus the composition line)',
      r.data.ok && r.data.stats.mode === 'free'
      && /CONCEPT relatives/.test(kinReq.prompt)
      && /concept relative \d+: "a mitred tower-warden construct"/.test(kinReq.prompt)
      && !/Composition:/.test(kinReq.prompt)
      && !/bishop_rook|darkness_earth/.test(kinReq.prompt), kinReq && kinReq.prompt);   // no id leaks
    check('single-card inference writes nothing',
      !readSbox('data/cards/apitest_kin.json').find(e => e.id === 'darkness_earth_bishop_rook').tool);
    // persist: true = the tree's per-item action — same inference, written onto the entry
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_pawn', persist: true });
    check('per-item inference persists onto the entry', r.data.persisted && r.data.stats
      && readSbox('data/cards/apitest_kin_lib.json').find(e => e.id === 'darkness_earth_pawn').tool.art.prompt === KIN_PROMPT,
      JSON.stringify(r.data));
    r = await api('/api/state');
    check('state flags entries carrying a recipe',
      r.data.game.card.find(c => c.id === 'darkness_earth_pawn').recipe === true
      && !r.data.game.card.find(c => c.id === 'darkness_earth_bishop_rook').recipe);
    // batch = a polled server-side job (the UI must survive re-renders/reloads)
    r = await api('/api/art/infer-recipes', { type: 'card', file: 'apitest_kin.json' });
    check('batch inference starts a job', r.status === 200 && !!r.data.jobId, JSON.stringify(r.data));
    let kinJob = null;
    for (let i = 0; i < 100; i++) {
      await new Promise(ok => setTimeout(ok, 100));
      kinJob = (await api('/api/art/infer-job?id=' + r.data.jobId)).data;
      if (kinJob.status !== 'running') break;
    }
    check('inference job completes with per-entry results and progress counts',
      kinJob.status === 'done' && kinJob.total === 1 && kinJob.done === 1
      && kinJob.results.find(x => x.id === 'darkness_earth_bishop_rook').prompt === KIN_PROMPT
      && kinJob.results.find(x => x.id === 'darkness_earth_knight').skipped, JSON.stringify(kinJob));
    check('batch job persisted recipes, skipping authored ones',
      readSbox('data/cards/apitest_kin.json').find(e => e.id === 'darkness_earth_bishop_rook').tool.art.prompt === KIN_PROMPT
      && readSbox('data/cards/apitest_kin.json').find(e => e.id === 'darkness_earth_bishop_rook').tool.art.ref.path === 'assets/cards/bishop_rook.png'
      && readSbox('data/cards/apitest_kin.json').find(e => e.id === 'darkness_earth_knight').tool.art.prompt === 'already authored');
    check('running jobs surface in state for UI reattachment',
      Array.isArray((await api('/api/state')).data.inferJobs));
    // adherence threads through the BATCH too (the bulk path is the primary use)
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_kin2.json'), JSON.stringify([
      { id: 'darkness_earth_rook', display_name: 'Grave Turret', cost: 3, attack: 2, health: 9, speed: 1,
        elements: ['darkness', 'earth'], chess_pieces: ['rook'] }]));
    r = await api('/api/art/infer-recipes', { type: 'card', file: 'apitest_kin2.json', adherence: 'replicate' });
    for (let i = 0; i < 100; i++) {
      await new Promise(ok => setTimeout(ok, 100));
      if ((await api('/api/art/infer-job?id=' + r.data.jobId)).data.status !== 'running') break;
    }
    check('batch inference honors the chosen adherence',
      /SAME illustration, re-themed/.test(kinReq.prompt), kinReq && kinReq.prompt);
    r = await api('/api/settings', { kinAdherence: 'replicate' });
    check('kin adherence default persists in settings', r.data.settings.kinAdherence === 'replicate');
    r = await api('/api/settings', { kinAdherence: 'bogus' });
    check('bad kinAdherence rejected', r.status === 400);
    await api('/api/settings', { kinAdherence: 'concept' });
    fakeKin.close();

    // ── ⛓ multi-step flows: a fake ComfyUI proves the chain, the fan-out and the pick ──
    const comfyReqs = [];
    const fakeComfy = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        const u = rq.url;
        rs.setHeader('Content-Type', 'application/json');
        if (u.startsWith('/upload/image')) {
          comfyReqs.push({ upload: true });
          rs.end(JSON.stringify({ name: 'up_' + comfyReqs.length + '.png' }));
        } else if (u === '/prompt') {
          comfyReqs.push({ wf: JSON.parse(b).prompt });
          rs.end(JSON.stringify({ prompt_id: 'p' + comfyReqs.length }));
        } else if (u.startsWith('/history/')) {
          const pid = u.slice('/history/'.length);
          rs.end(JSON.stringify({ [pid]: { status: { status_str: 'success' },
            outputs: { 60: { images: [{ filename: 'o.png', subfolder: '', type: 'output' }] } } } }));
        } else if (u.startsWith('/view')) {
          rs.setHeader('Content-Type', 'image/png');
          rs.end(PNG1x1);
        } else { rs.statusCode = 404; rs.end('{}'); }
      });
    });
    await new Promise(ok => fakeComfy.listen(8485, ok));
    await api('/api/settings', { comfyUrl: 'http://127.0.0.1:8485' });
    r = await api('/api/art/flow', { type: 'card', id: 'apitest_flip', prompt: 'x',
      steps: [{ model: 'flux2', samples: 8 }, { model: 'krea2', samples: 8, denoise: 0.5 }] });
    check('flow cap rejects oversized fan-outs', r.status === 400 && /cap/.test(r.data.error || ''), r.data.error);
    r = await api('/api/art/flow', { type: 'card', id: 'apitest_flip', prompt: 'x',
      steps: [{ model: 'flux2', samples: 1 }, { model: 'ideogram4', samples: 1 }] });
    check('flow rejects input-less models on later steps', r.status === 400, r.data.error);
    r = await api('/api/art/flow', { type: 'card', id: 'apitest_flip', prompt: 'a mystic pawn',
      steps: [{ model: 'flux2', samples: 1 }, { model: 'krea2', samples: 2, denoise: 0.5 }] });
    check('flow starts a job with the multiplied total', r.status === 200 && !!r.data.jobId && r.data.total === 3,
      JSON.stringify(r.data));
    let fj = null;
    for (let i = 0; i < 200; i++) {
      await new Promise(ok => setTimeout(ok, 150));
      fj = (await api('/api/art/flow-job?id=' + r.data.jobId)).data;
      if (fj.status !== 'running') break;
    }
    check('flow completes the fan-out tree', fj.status === 'done' && fj.done === 3
      && fj.nodes.length === 3 && fj.nodes[0].step === 1 && fj.nodes[0].parent === 0
      && fj.nodes.filter(n => n.step === 2 && n.parent === 1).length === 2, JSON.stringify(fj));
    check('step-2 generations chain off the parent image',
      comfyReqs.filter(q => q.wf && JSON.stringify(q.wf).includes('LoadImage')).length === 2);
    const flowDirAbs = path.join(WS_DIR, 'art', '_flow', 'card', 'apitest_flip');
    check('flow candidates are on disk with a manifest',
      fs.existsSync(path.join(flowDirAbs, fj.nodes[2].file))
      && JSON.parse(fs.readFileSync(path.join(flowDirAbs, 'flow.json'), 'utf8')).nodes.length === 3);
    const imgRes = await fetch(BASE + '/flowart/card/apitest_flip/' + fj.nodes[1].file);
    check('flow candidates are served', imgRes.status === 200
      && Buffer.from(await imgRes.arrayBuffer()).equals(PNG1x1));
    r = await api('/api/art/flow-pick', { type: 'card', id: 'apitest_flip', file: fj.nodes[1].file });
    check('picking a candidate promotes it to workspace art', r.data.ok
      && r.data.node && r.data.node.seed != null
      && fs.readFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_flip.png')).equals(PNG1x1),
      JSON.stringify(r.data));
    check('flow-result returns the manifest after the fact',
      (await api('/api/art/flow-result?type=card&id=apitest_flip')).data.result.nodes.length === 3);
    check('state lists running flows for UI reattachment',
      Array.isArray((await api('/api/state')).data.flowJobs));
    r = await api('/api/settings', { flowPresets: { housestyle: JSON.stringify([{ model: 'flux2', samples: 1 }]) } });
    check('flow presets persist', (r.data.settings.flowPresets.housestyle || '').includes('flux2'));
    // anchored flow: step 1 grows from a concept image instead of from scratch
    r = await api('/api/art/flow', { type: 'card', id: 'apitest_flip', prompt: 'x',
      anchor: { source: 'game', path: 'assets/cards/bishop_queen.png' },
      steps: [{ model: 'ideogram4', samples: 1 }] });
    check('anchored flow rejects input-less step-1 models', r.status === 400, r.data.error);
    const wfCountBefore = comfyReqs.filter(q => q.wf).length;
    r = await api('/api/art/flow', { type: 'card', id: 'apitest_flip', prompt: 'an anchored pawn',
      anchor: { source: 'game', path: 'assets/cards/bishop_queen.png' },
      steps: [{ model: 'krea2', samples: 1, denoise: 0.4 }] });
    check('anchored flow starts', r.status === 200 && !!r.data.jobId, JSON.stringify(r.data));
    for (let i = 0; i < 200; i++) {
      await new Promise(ok => setTimeout(ok, 150));
      fj = (await api('/api/art/flow-job?id=' + r.data.jobId)).data;
      if (fj.status !== 'running') break;
    }
    const anchoredWfs = comfyReqs.filter(q => q.wf).slice(wfCountBefore);
    check('anchored step 1 runs img2img off the anchor with its denoise',
      fj.status === 'done' && fj.nodes.length === 1 && fj.nodes[0].denoise === 0.4
      && anchoredWfs.length === 1 && JSON.stringify(anchoredWfs[0].wf).includes('LoadImage'),
      JSON.stringify({ fj, wf: anchoredWfs.length }));
    check('anchored flow manifest records the anchor',
      JSON.parse(fs.readFileSync(path.join(flowDirAbs, 'flow.json'), 'utf8')).anchor.path === 'assets/cards/bishop_queen.png');

    // ── the generation pool: every flow candidate landed there, swappable at will ──
    r = await api('/api/art/pool?type=card&id=apitest_flip');
    check('every generation pooled with metadata', r.data.pool.length === 4
      && r.data.pool.every(e => e.source === 'flow' && e.seed != null && /^p[0-9]+\.png$/.test(e.file)),
      JSON.stringify(r.data.pool));
    const poolEntry = r.data.pool[0];
    const poolImg = await fetch(BASE + `/poolart/card/apitest_flip/${poolEntry.file}`);
    check('pool images are served', poolImg.status === 200
      && Buffer.from(await poolImg.arrayBuffer()).equals(PNG1x1));
    r = await api('/api/art/pool-use', { type: 'card', id: 'apitest_flip', file: poolEntry.file });
    check('pool-use swaps the workspace art', r.data.ok
      && fs.readFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_flip.png')).equals(PNG1x1));
    r = await api('/api/art/pool-delete', { type: 'card', id: 'apitest_flip', file: poolEntry.file });
    check('pool-delete removes an entry', r.data.ok && r.data.count === 3);

    // ── ⛓ Quick Flow batch: appointed flow across a file, auto-pick from the last step ──
    const fakeKin2 = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ response: 'a quick-flow prompt' }));
      });
    });
    await new Promise(ok => fakeKin2.listen(8482, ok));
    r = await api('/api/settings', { quickFlow: { steps: [{ model: 'ideogram4', samples: 1 }, { model: 'ideogram4', samples: 1 }], anchor: 'none' } });
    check('invalid quick flow rejected at appointment', r.status === 400, r.data.error);
    r = await api('/api/settings', { quickFlow: { steps: [{ model: 'krea2', samples: 2, denoise: 0.5 }], anchor: 'none' } });
    check('quick flow appointment persists', r.data.settings.quickFlow.steps[0].model === 'krea2');
    r = await api('/api/art/flow-batch', { type: 'card', file: 'nope.json' });
    check('quick flow batch on an empty file 404s', r.status === 404);
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_qf.json'), JSON.stringify([
      { id: 'apitest_qf_a', display_name: 'QA', cost: 1, attack: 1, health: 1, speed: 1,
        elements: ['fire'], chess_pieces: ['pawn'], tool: { art: { prompt: 'an authored fire pawn' } } },
      { id: 'apitest_qf_b', display_name: 'QB', cost: 1, attack: 1, health: 1, speed: 1,
        elements: ['fire'], chess_pieces: ['queen'] },
    ]));
    r = await api('/api/art/flow-batch', { type: 'card', file: 'apitest_qf.json', fill: true, adherence: 'free' });
    check('quick flow batch starts', r.status === 200 && !!r.data.jobId, JSON.stringify(r.data));
    let qj = null, sawCurrent = false;
    for (let i = 0; i < 300; i++) {
      await new Promise(ok => setTimeout(ok, 150));
      qj = (await api('/api/art/flow-batch-job?id=' + r.data.jobId)).data;
      if (qj.status === 'running' && qj.currentFlow && qj.currentId) sawCurrent = true;
      if (qj.status !== 'running') break;
    }
    check('monitor snapshot exposes the current card and live image progress', sawCurrent);
    check('quick flow fills missing recipes, flows every card and picks finals',
      qj.status === 'done'
      && qj.results.filter(x => x.picked).length === 2
      && readSbox('data/cards/apitest_qf.json').find(e => e.id === 'apitest_qf_b').tool.art.prompt === 'a quick-flow prompt'
      && fs.existsSync(path.join(WS_DIR, 'art', 'card', 'apitest_qf_a.png'))
      && fs.existsSync(path.join(WS_DIR, 'art', 'card', 'apitest_qf_b.png')), JSON.stringify(qj));
    check('picks come from the LAST step', qj.results.filter(x => x.picked).every(x => /^1_/.test(x.picked)));
    check('running quick-flow batches surface in state',
      Array.isArray((await api('/api/state')).data.flowBatchJobs));
    // stop: halts promptly (in-flight image aborted best-effort), nothing gets picked
    r = await api('/api/art/flow-batch', { type: 'card', file: 'apitest_qf.json', fill: false });
    check('quick flow batch restarts on the same file', r.status === 200 && !!r.data.jobId);
    await api('/api/art/flow-batch-stop', { id: r.data.jobId });
    let sj = null;
    for (let i = 0; i < 100; i++) {
      await new Promise(ok => setTimeout(ok, 150));
      sj = (await api('/api/art/flow-batch-job?id=' + r.data.jobId)).data;
      if (sj.status !== 'running') break;
    }
    check('stop halts the batch cleanly with no picks',
      sj.status === 'stopped' && sj.results.filter(x => x.picked).length === 0, JSON.stringify(sj));
    fakeKin2.close();
    fakeComfy.close();

    // ── single-object files keep working (statuses) ──
    r = await api('/api/game/item?type=status&id=poison');
    await api('/api/game/save', { type: 'status', file: 'poison.json', data: Object.assign({}, r.data.data, { display_name: 'Toxin' }) });
    check('single-object file edit', readSbox('data/statuses/poison.json').display_name === 'Toxin');
    await api('/api/game/restore', { type: 'status', id: 'poison' });
    check('single-object revert', readSbox('data/statuses/poison.json').display_name === 'Poison');

    // ── generation workflow builders (unchanged surface) ──
    const srv = require(path.join(TOOL, 'server.js'));
    const plain = srv.buildFluxWorkflow('x', 512, 512, 20, 4, 1, 'p', false);
    const withRef = srv.buildFluxWorkflow('x', 512, 512, 20, 4, 1, 'p', false, 'ref.png');
    check('flux2 ref chain intact', JSON.stringify(withRef[21].inputs.conditioning) === '["73",0]'
      && JSON.stringify(plain[21].inputs.conditioning) === '["20",0]');
    const withLora = srv.buildFluxWorkflow('x', 512, 512, 8, 4, 1, 'p', false, null, 'turbo.safetensors', 0.9);
    check('flux2 turbo lora intact', JSON.stringify(withLora[30].inputs.model) === '["15",0]');
    const krea = srv.buildKrea2Workflow('x', 1024, 1024, 8, 1.0, 1, 'p', false);
    check('krea2 graph intact', krea[11].inputs.type === 'krea2' && krea[40].class_type === 'KSampler');
    const kreaImg2img = srv.buildKrea2Workflow('x', 1024, 1024, 8, 1.0, 1, 'p', false, 'ref.png', 'img2img', 0.6);
    check('krea2 img2img chain intact', kreaImg2img[34].class_type === 'VAEEncode'
      && kreaImg2img[40].inputs.denoise === 0.6 && JSON.stringify(kreaImg2img[40].inputs.positive) === '["20",0]');
    const kreaRef = srv.buildKrea2Workflow('x', 1024, 1024, 8, 1.0, 1, 'p', false, 'ref.png', 'reference');
    check('krea2 reference chain intact', kreaRef[83].class_type === 'ReferenceLatent'
      && JSON.stringify(kreaRef[40].inputs.positive) === '["83",0]' && kreaRef[34].class_type === 'EmptyLatentImage');
    const ideo = srv.buildIdeogram4Workflow('x', 1024, 1024, 20, 7.0, 1, 'p', false);
    check('ideogram4 graph intact', ideo[30].class_type === 'DualModelGuider' && ideo[22].class_type === 'CFGOverride');
    const nova = srv.buildNovaCartoonWorkflow('a cat', '', 1024, 1536, 30, 5.0, 1, 'p', false);
    check('novacartoon graph intact', nova[11].inputs.stop_at_clip_layer === -2 && nova[34].inputs.width === 832);
    r = await api('/api/state');
    check('art model registry exposed', r.data.artModels && r.data.artModels.novacartoon.supportsNegative === true);
    check('krea2 refModes exposed', r.data.artModels.krea2.supportsRef === true
      && r.data.artModels.krea2.refModes.some(m => m.value === 'img2img')
      && r.data.artModels.krea2.refModes.some(m => m.value === 'reference'));

    // ── static ──
    const page = await fetch(BASE + '/');
    check('index.html serves', page.status === 200 && (await page.text()).includes('CardGame Authoring'));
    const traversal = await fetch(BASE + '/..%2fserver.js');
    check('path traversal blocked', traversal.status !== 200 || !(await traversal.text()).includes('CARDGAME_ROOT'));
  } finally {
    server.kill();
    fs.rmSync(SANDBOX, { recursive: true, force: true });
    fs.rmSync(WS_DIR, { recursive: true, force: true });
  }

  console.log(failures ? `\n${failures} FAILURE(S)` : '\nALL PASS');
  process.exit(failures ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
