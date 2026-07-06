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
    env: Object.assign({}, process.env, { CARDGAME_ROOT: SANDBOX, CARDGAME_WORKSPACE: WS_DIR }),
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
    fakeOllama.close();
    r = await api('/api/art/prompt', { type: 'card', name: 'Pawn', summary: [] });
    check('llm unreachable reports cleanly', r.status === 502 && /unreachable/i.test(r.data.error));

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
