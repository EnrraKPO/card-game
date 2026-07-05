/* api_test.js — exercises every server flow against a SANDBOX game root AND a fully
 * isolated tool workspace, so a test run can never read, overwrite, or reset anything in
 * the real Tool/workspace (authored drafts, installed.json, edits.json, settings.json).
 * Run: node test/api_test.js */
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

// Seed the sandbox with a minimal game data layout so vocab scanning has content.
for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map', 'assets/cards', 'assets/relics', 'assets/abilities'])
  fs.mkdirSync(path.join(SANDBOX, d), { recursive: true });
fs.writeFileSync(path.join(SANDBOX, 'data/cards/base.json'), JSON.stringify([
  { id: 'pawn', display_name: 'Pawn', cost: 1, attack: 1, health: 2, speed: 3, chess_pieces: ['pawn'] },
  { id: 'goblin_cutter', display_name: 'Goblin Cutter', cost: 1, attack: 2, health: 1, speed: 4, enemy_only: true },
  { id: 'goblin_warlord', display_name: 'Goblin Warlord', cost: 0, attack: 3, health: 20, speed: 2, is_king: true, enemy_only: true },
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

async function main() {
  const server = spawn(process.execPath, [path.join(TOOL, 'server.js'), String(PORT)], {
    env: Object.assign({}, process.env, { CARDGAME_ROOT: SANDBOX, CARDGAME_WORKSPACE: WS_DIR }),
    stdio: 'inherit',
  });
  await new Promise(r => setTimeout(r, 700));

  try {
    // ── state & vocab ──
    let r = await api('/api/state');
    check('GET /api/state 200', r.status === 200);
    check('vocab has sandbox card', r.data.vocab.cards.some(c => c.id === 'pawn'));
    check('vocab has sandbox status', r.data.vocab.statuses.some(s => s.id === 'poison'));
    check('vocab exposes triggers', Array.isArray(r.data.vocab.triggers) && r.data.vocab.triggers.includes('on_attack'));
    check('gameRoot is sandbox', r.data.gameRoot === SANDBOX);

    // ── save + validate: one item of every type ──
    const samples = {
      card: { id: 'apitest_card', display_name: 'API Test Card', cost: 2, attack: 3, health: 4, speed: 3,
        elements: ['fire'], chess_pieces: ['pawn'],
        effects: [{ trigger: 'on_attack', targeting_policy: 'attack_target', status: { id: 'poison', stacks: 1 } }] },
      relic: { id: 'apitest_relic', display_name: 'API Test Relic', description: 'x', color: 'aabbcc', letter: 'T', price: 50,
        effects: [{ kind: 'modifier', key: 'unit.attack', amount: 1 }] },
      status: { id: 'apitest_status', display_name: 'Testy', beneficial: false, color: '5a8f3a', glyph: 'T',
        decay: 'stacks', decay_phase: 'turn_start', stacking: 'stack', max_stacks: 9,
        effects: [{ trigger: 'on_turn_start', targeting_policy: 'self', attribute: 'health', amount: -1 }] },
      ability: { id: 'apitest_ability', display_name: 'Zap', cost: { mana: 1, tap: true },
        effects: [{ trigger: 'on_play', targeting_policy: 'manual', attribute: 'health', amount: -2 }] },
      charm: { id: 'apitest_charm', display_name: 'Charmy', color: 'aabbcc', letter: 'C', stats: { attack: 2 } },
      upgrade: { id: 'apitest_upgrade', display_name: 'Tree', color: 'aabbcc',
        nodes: [{ id: 'root', display_name: 'Root', cost: 1, icon: 'X', row: 0, col: 0, requires: [],
          effects: [{ key: 'mana.initial', amount: 1 }] }] },
      encounter: { id: 'apitest_enc', node_type: 'combat', min_floor: 0, max_floor: 999, weight: 1,
        enemy_king: 'goblin_warlord', enemy_pool: [{ id: 'goblin_cutter', weight: 2 }], pick_count: [10, 14],
        gold_reward: [10, 20], exp_reward: 1, ai: 'default', reward_pool: 'default' },
      nodeweights: { id: 'apitest_nw', bands: [{ min_floor: 1, max_floor: 5, weights: { combat: 0.5, shop: 0.5 } }] },
    };

    for (const [type, data] of Object.entries(samples)) {
      r = await api('/api/item/save', { type, data });
      check(`save ${type}`, r.status === 200, JSON.stringify(r.data));
      r = await api('/api/validate', { type, data });
      check(`validate ${type}`, r.data.ok === true, r.data.error);
    }

    // ── invalid payloads are rejected ──
    r = await api('/api/validate', { type: 'card', data: { id: 'Bad ID!' } });
    check('bad id rejected', !r.data.ok);
    r = await api('/api/validate', { type: 'card', data: { id: 'x', display_name: 'X', cost: 1, attack: 1, health: 1, speed: 1, effects: [{ trigger: 'on_play', targeting_policy: 'self' }] } });
    check('payload-less effect rejected', !r.data.ok);
    r = await api('/api/validate', { type: 'relic', data: { id: 'x', display_name: 'X', effects: [] } });
    check('effect-less relic rejected', !r.data.ok);
    r = await api('/api/validate', { type: 'upgrade', data: { id: 'x', display_name: 'X', nodes: [{ id: 'a', requires: ['ghost'] }] } });
    check('bad node requirement rejected', !r.data.ok);
    r = await api('/api/validate', { type: 'encounter', data: { id: 'x', node_type: 'combat', enemy_pool: [{ id: 'c' }], pick_count: [9, 3] } });
    check('inverted pick_count rejected', !r.data.ok);
    r = await api('/api/validate', { type: 'card', data: { id: 'x', _derive_stats: true, elements: ['fire'], effects: [] } });
    check('derived-stat card accepted without stats', r.data.ok === true, r.data.error);

    // ── install: files land in the sandbox ──
    for (const type of Object.keys(samples)) {
      r = await api('/api/item/install', { type, id: samples[type].id });
      check(`install ${type}`, r.status === 200, JSON.stringify(r.data));
    }
    const cardFile = path.join(SANDBOX, 'data/cards/tool_card_apitest_card.json');
    check('card json deployed', fs.existsSync(cardFile));
    const deployed = JSON.parse(fs.readFileSync(cardFile, 'utf8'));
    check('deployed card round-trips', deployed.id === 'apitest_card' && deployed.effects[0].status.id === 'poison');
    check('no tool metadata leaks', !Object.keys(deployed).some(k => k.startsWith('_')));
    const nwFile = path.join(SANDBOX, 'data/map/tool_nodeweights_apitest_nw.json');
    check('nodeweights deployed as raw band array', fs.existsSync(nwFile) && Array.isArray(JSON.parse(fs.readFileSync(nwFile, 'utf8'))));
    const nwParsed = JSON.parse(fs.readFileSync(nwFile, 'utf8'));
    check('nodeweights band shape', nwParsed[0].min_floor === 1 && nwParsed[0].weights.combat === 0.5);

    // installed flag shows up in state
    r = await api('/api/state');
    check('state reports installed', r.data.items.card.find(x => x.id === 'apitest_card').installed === true);

    // ── workspace isolation: a test run must NEVER touch the real Tool/workspace ──
    // (regression for a real incident: installed.json/edits.json lived in Tool/workspace
    // regardless of CARDGAME_ROOT, so a sandboxed test run's bookkeeping clobbered/reset the
    // real tool's install & edit tracking — CARDGAME_WORKSPACE fixes this).
    const realManifest = path.join(TOOL, 'workspace', 'installed.json');
    const realHadIt = fs.existsSync(realManifest) && JSON.parse(fs.readFileSync(realManifest, 'utf8'))['card/apitest_card'];
    check('this run\'s install did NOT land in the real workspace manifest', !realHadIt);
    check('it landed in the isolated sandbox workspace instead',
      fs.existsSync(path.join(WS_DIR, 'installed.json')) &&
      JSON.parse(fs.readFileSync(path.join(WS_DIR, 'installed.json'), 'utf8'))['card/apitest_card']);

    // ── art install path: fake a workspace art png for the relic, reinstall ──
    const artDir = path.join(WS_DIR, 'art', 'relic');
    fs.mkdirSync(artDir, { recursive: true });
    fs.writeFileSync(path.join(artDir, 'apitest_relic.png'), Buffer.from('89504e470d0a1a0a', 'hex'));
    r = await api('/api/item/install', { type: 'relic', id: 'apitest_relic' });
    check('reinstall relic with art', r.status === 200, JSON.stringify(r.data));
    check('art copied to game assets', fs.existsSync(path.join(SANDBOX, 'assets/relics/apitest_relic.png')));

    // refusal to clobber foreign art
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/apitest_card.png'), 'not ours');
    fs.mkdirSync(path.join(WS_DIR, 'art', 'card'), { recursive: true });
    fs.writeFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_card.png'), Buffer.from('89504e470d0a1a0a', 'hex'));
    r = await api('/api/item/install', { type: 'card', id: 'apitest_card' });
    check('foreign art protected (409)', r.status === 409, JSON.stringify(r.data));
    check('failed install rolled back its json', !fs.existsSync(cardFile));
    check('foreign art untouched', fs.readFileSync(path.join(SANDBOX, 'assets/cards/apitest_card.png'), 'utf8') === 'not ours');
    fs.unlinkSync(path.join(SANDBOX, 'assets/cards/apitest_card.png'));
    fs.unlinkSync(path.join(WS_DIR, 'art', 'card', 'apitest_card.png'));
    r = await api('/api/item/install', { type: 'card', id: 'apitest_card' });
    check('card reinstalls after conflict cleared', r.status === 200);

    // ── conditioned modifiers validate ──
    r = await api('/api/validate', { type: 'relic', data: { id: 'x', display_name: 'X',
      effects: [{ kind: 'modifier', key: 'unit.health', amount: 1, conditions: [{ composition: ['pawn'] }] }] } });
    check('modifier with composition condition accepted', r.data.ok === true, r.data.error);
    r = await api('/api/validate', { type: 'relic', data: { id: 'x', display_name: 'X',
      effects: [{ kind: 'modifier', key: 'unit.attack', amount: 1, conditions: [{ attribute: 'bogus', comparator: 'gte', value: 1 }] }] } });
    check('modifier with bad condition rejected', !r.data.ok);

    // ── enemy card art routes to assets/cards/enemies/ ──
    const enemyCard = { id: 'apitest_enemy', display_name: 'Rat', cost: 1, attack: 1, health: 1, speed: 1, enemy_only: true };
    await api('/api/item/save', { type: 'card', data: enemyCard });
    fs.mkdirSync(path.join(WS_DIR, 'art', 'card'), { recursive: true });
    fs.writeFileSync(path.join(WS_DIR, 'art', 'card', 'apitest_enemy.png'), Buffer.from('89504e470d0a1a0a', 'hex'));
    r = await api('/api/item/install', { type: 'card', id: 'apitest_enemy' });
    check('enemy card installs', r.status === 200, JSON.stringify(r.data));
    check('enemy art deployed under enemies/', fs.existsSync(path.join(SANDBOX, 'assets/cards/enemies/apitest_enemy.png')));
    await api('/api/item/uninstall', { type: 'card', id: 'apitest_enemy' });
    check('enemy art removed on uninstall', !fs.existsSync(path.join(SANDBOX, 'assets/cards/enemies/apitest_enemy.png')));
    await api('/api/item/delete', { type: 'card', id: 'apitest_enemy' });

    // ── editing EXISTING game content in place ──
    r = await api('/api/state');
    check('state lists game content', r.data.game.card.some(g => g.id === 'pawn'));
    r = await api('/api/game/item?type=card&id=pawn');
    check('game item fetch', r.status === 200 && r.data.data.attack === 1 && r.data.file === 'base.json');

    // installed game art is detected and served
    const PNG1x1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
    fs.mkdirSync(path.join(SANDBOX, 'assets/cards/enemies'), { recursive: true });
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'), PNG1x1);
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/enemies/goblin_cutter.png'), PNG1x1);
    r = await api('/api/state');
    check('game entry reports its installed art', r.data.game.card.find(g => g.id === 'pawn').art === 'assets/cards/pawn.png');
    check('enemy art found under enemies/', r.data.game.card.find(g => g.id === 'goblin_cutter').art === 'assets/cards/enemies/goblin_cutter.png');
    check('art-less entry reports none', r.data.game.card.find(g => g.id === 'goblin_warlord').art === null);
    r = await api('/api/game/item?type=card&id=pawn');
    check('game item carries gameArt', r.data.gameArt === 'assets/cards/pawn.png');
    const artRes = await fetch(BASE + '/gameart/assets/cards/pawn.png');
    check('game art serves', artRes.status === 200 && (await artRes.arrayBuffer()).byteLength === PNG1x1.length);
    fs.unlinkSync(path.join(SANDBOX, 'assets/cards/pawn.png'));
    fs.unlinkSync(path.join(SANDBOX, 'assets/cards/enemies/goblin_cutter.png'));

    // apply an edit to an entry inside an ARRAY file
    const editedPawn = Object.assign({}, r.data.data, { attack: 7 });
    r = await api('/api/game/apply', { type: 'card', id: 'pawn', data: editedPawn });
    check('game edit applies', r.status === 200, JSON.stringify(r.data));
    let baseNow = JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8'));
    check('edited entry changed in file', baseNow.find(c => c.id === 'pawn').attack === 7);
    check('sibling entries untouched', baseNow.find(c => c.id === 'goblin_cutter').attack === 2 && baseNow.length === 3);
    r = await api('/api/state');
    check('state flags entry as edited', r.data.game.card.find(g => g.id === 'pawn').edited === true);

    // id changes and unknown ids are rejected
    r = await api('/api/game/apply', { type: 'card', id: 'pawn', data: Object.assign({}, editedPawn, { id: 'renamed' }) });
    check('game edit id change rejected', r.status === 400);
    r = await api('/api/game/apply', { type: 'card', id: 'ghost_card', data: { id: 'ghost_card', display_name: 'G', cost: 1, attack: 1, health: 1, speed: 1 } });
    check('unknown game id rejected', r.status === 400);

    // art replacement with backup: give the sandbox pawn game art + workspace art
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'), 'original-art');
    fs.writeFileSync(path.join(WS_DIR, 'art', 'card', 'pawn.png'), Buffer.from('89504e470d0a1a0a', 'hex'));
    r = await api('/api/game/apply', { type: 'card', id: 'pawn', data: editedPawn, applyArt: true });
    check('game art replaced', r.status === 200 && r.data.art.length === 1, JSON.stringify(r.data));
    check('replaced art is the generated one', fs.readFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'), 'utf8') !== 'original-art');

    // restore puts back BOTH the entry and the original art
    r = await api('/api/game/restore', { type: 'card', id: 'pawn' });
    check('game restore ok', r.status === 200, JSON.stringify(r.data));
    baseNow = JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8'));
    check('entry restored', baseNow.find(c => c.id === 'pawn').attack === 1);
    check('original art restored', fs.readFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'), 'utf8') === 'original-art');
    r = await api('/api/state');
    check('edited flag cleared after restore', r.data.game.card.find(g => g.id === 'pawn').edited === false);
    fs.unlinkSync(path.join(SANDBOX, 'assets/cards/pawn.png'));
    fs.unlinkSync(path.join(WS_DIR, 'art', 'card', 'pawn.png'));

    // restore is BYTE-exact even though apply reformats the file
    const oddlyFormatted = '[\n  {"id":"pawn","display_name":"Pawn",   "cost":1,"attack":1,"health":2,"speed":3,"chess_pieces":["pawn"]},\n  {"id":"goblin_cutter","display_name":"Goblin Cutter","cost":1,"attack":2,"health":1,"speed":4,"enemy_only":true},\n  {"id":"goblin_warlord","display_name":"Goblin Warlord","cost":0,"attack":3,"health":20,"speed":2,"is_king":true,"enemy_only":true}\n]\n';
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/base.json'), oddlyFormatted);
    r = await api('/api/game/item?type=card&id=pawn');
    await api('/api/game/apply', { type: 'card', id: 'pawn', data: Object.assign({}, r.data.data, { attack: 5 }) });
    check('apply reformats the file', fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8') !== oddlyFormatted);
    await api('/api/game/restore', { type: 'card', id: 'pawn' });
    check('restore is byte-exact (original formatting back)',
      fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8') === oddlyFormatted);

    // single-object file edit (statuses/poison.json)
    r = await api('/api/game/item?type=status&id=poison');
    const editedPoison = Object.assign({}, r.data.data, { display_name: 'Toxin' });
    r = await api('/api/game/apply', { type: 'status', id: 'poison', data: editedPoison });
    check('single-object file edit applies', r.status === 200, JSON.stringify(r.data));
    check('single-object file keeps shape', !Array.isArray(JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/statuses/poison.json'), 'utf8'))));
    await api('/api/game/restore', { type: 'status', id: 'poison' });
    check('single-object restore', JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/statuses/poison.json'), 'utf8')).display_name === 'Poison');

    // regression: restoring SEVERAL entries that share one file must end up byte-exact, no
    // matter the restore order — this was a real bug (sibling fileHash went stale on a partial
    // restore, so the LAST restore wrongly thought the file had been touched externally and
    // fell back to a value-only rewrite that never recovered the original formatting).
    const sharedOriginal = '[\n  {"id":"pawn","display_name":"Pawn","cost":1,"attack":1,"health":2,"speed":3,"chess_pieces":["pawn"]},\n  {"id":"goblin_cutter","display_name":"Goblin Cutter","cost":1,"attack":2,"health":1,"speed":4,"enemy_only":true},\n  {"id":"goblin_warlord","display_name":"Goblin Warlord","cost":0,"attack":3,"health":20,"speed":2,"is_king":true,"enemy_only":true}\n]\n';
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/base.json'), sharedOriginal);
    const gp = await api('/api/game/item?type=card&id=pawn');
    const gc = await api('/api/game/item?type=card&id=goblin_cutter');
    await api('/api/game/apply', { type: 'card', id: 'pawn', data: Object.assign({}, gp.data.data, { attack: 11 }) });
    await api('/api/game/apply', { type: 'card', id: 'goblin_cutter', data: Object.assign({}, gc.data.data, { attack: 12 }) });
    await api('/api/game/restore', { type: 'card', id: 'pawn' });   // partial: goblin_cutter edit remains
    check('partial restore keeps sibling edit intact', JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8')).find(c => c.id === 'goblin_cutter').attack === 12);
    await api('/api/game/restore', { type: 'card', id: 'goblin_cutter' });   // last one — must be byte-exact now
    check('restoring the LAST of several siblings is byte-exact',
      fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8') === sharedOriginal);

    // nodeweights: whole-file pseudo-entry
    fs.writeFileSync(path.join(SANDBOX, 'data/map/node_weights.json'),
      JSON.stringify([{ min_floor: 1, max_floor: 999, weights: { combat: 0.5, rest: 0.5 } }]));
    r = await api('/api/game/item?type=nodeweights&id=node_weights');
    check('nodeweights game file listed as pseudo-entry', r.status === 200 && Array.isArray(r.data.data.bands));
    const editedNw = { id: 'node_weights', bands: [{ min_floor: 1, max_floor: 999, weights: { combat: 0.3, event: 0.7 } }] };
    r = await api('/api/game/apply', { type: 'nodeweights', id: 'node_weights', data: editedNw });
    check('nodeweights edit applies', r.status === 200, JSON.stringify(r.data));
    check('nodeweights file stays a raw array', Array.isArray(JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/map/node_weights.json'), 'utf8'))));
    await api('/api/game/restore', { type: 'nodeweights', id: 'node_weights' });
    check('nodeweights restore', JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/map/node_weights.json'), 'utf8'))[0].weights.combat === 0.5);

    // ── uninstall removes exactly what was written ──
    for (const type of Object.keys(samples)) {
      r = await api('/api/item/uninstall', { type, id: samples[type].id });
      check(`uninstall ${type}`, r.status === 200, JSON.stringify(r.data));
    }
    check('card json removed', !fs.existsSync(cardFile));
    check('relic art removed', !fs.existsSync(path.join(SANDBOX, 'assets/relics/apitest_relic.png')));
    // sandbox data dirs contain ONLY the seeded files again
    const leftovers = [];
    for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map', 'assets/relics', 'assets/cards', 'assets/abilities'])
      for (const f of fs.readdirSync(path.join(SANDBOX, d)))
        if (f.startsWith('tool_') || f.startsWith('apitest')) leftovers.push(d + '/' + f);
    check('no leftovers after uninstall', leftovers.length === 0, leftovers.join(', '));

    // ── delete cleans the workspace ──
    for (const type of Object.keys(samples)) {
      r = await api('/api/item/delete', { type, id: samples[type].id });
      check(`delete ${type}`, r.status === 200);
    }
    r = await api('/api/state');
    check('workspace clean of apitest items',
      Object.values(r.data.items).every(list => !list.some(x => x.id.startsWith('apitest_'))));

    // ── art generation depth: style settings + image reference ──
    r = await api('/api/settings', { artStyle: 'cartoon art style', stylePresets: { toon: 'cartoon art style', oil: 'oil painting' } });
    check('style settings save', r.data.settings.artStyle === 'cartoon art style' && r.data.settings.stylePresets.oil === 'oil painting');
    r = await api('/api/state');
    check('style settings persist in state', r.data.settings.artStyle === 'cartoon art style' && Object.keys(r.data.settings.stylePresets).length === 2);

    // reference workflow graph shape (no ComfyUI needed — pure builder)
    const { buildFluxWorkflow } = require(path.join(TOOL, 'server.js'));
    const plain = buildFluxWorkflow('x', 512, 512, 20, 4, 1, 'p', false);
    check('plain workflow has no ref nodes', !plain[70] && JSON.stringify(plain[21].inputs.conditioning) === '["20",0]');
    const withRef = buildFluxWorkflow('x', 512, 512, 20, 4, 1, 'p', false, 'ref.png');
    check('ref workflow chains ReferenceLatent', withRef[70].class_type === 'LoadImage'
      && withRef[70].inputs.image === 'ref.png'
      && withRef[73].class_type === 'ReferenceLatent'
      && JSON.stringify(withRef[73].inputs.latent) === '["72",0]'
      && JSON.stringify(withRef[21].inputs.conditioning) === '["73",0]');

    // turbo LoRA: settings persist + workflow graph shape
    r = await api('/api/settings', { turboLora: 'Flux_2-Turbo-LoRA_comfyui.safetensors', turboSteps: 8, turboStrength: 0.9 });
    check('turbo settings save', r.data.settings.turboLora === 'Flux_2-Turbo-LoRA_comfyui.safetensors'
      && r.data.settings.turboSteps === 8 && r.data.settings.turboStrength === 0.9);
    const withLora = buildFluxWorkflow('x', 512, 512, 8, 4, 1, 'p', false, null, 'turbo.safetensors', 0.9);
    check('lora workflow chains LoraLoaderModelOnly', withLora[15].class_type === 'LoraLoaderModelOnly'
      && withLora[15].inputs.lora_name === 'turbo.safetensors'
      && withLora[15].inputs.strength_model === 0.9
      && JSON.stringify(withLora[30].inputs.model) === '["15",0]');
    check('plain workflow keeps direct model', JSON.stringify(plain[30].inputs.model) === '["10",0]');
    const loraAndRef = buildFluxWorkflow('x', 512, 512, 8, 4, 1, 'p', false, 'ref.png', 'turbo.safetensors', 1.0);
    check('lora + ref combine', loraAndRef[15] && loraAndRef[73]
      && JSON.stringify(loraAndRef[30].inputs.model) === '["15",0]'
      && JSON.stringify(loraAndRef[21].inputs.conditioning) === '["73",0]');
    // turbo without a configured lora fails cleanly
    await api('/api/settings', { turboLora: '' });
    await api('/api/item/save', { type: 'card', data: { id: 'apitest_turbo', display_name: 'T', cost: 1, attack: 1, health: 1, speed: 1 } });
    r = await api('/api/art/generate', { type: 'card', id: 'apitest_turbo', prompt: 'x', turbo: true });
    check('turbo without lora rejected', r.status !== 200 && /no turbo LoRA/.test(r.data.error || ''), JSON.stringify(r.data));
    await api('/api/item/delete', { type: 'card', id: 'apitest_turbo' });

    // useRef without any current art fails cleanly (before touching ComfyUI)
    await api('/api/item/save', { type: 'card', data: { id: 'apitest_noart', display_name: 'N', cost: 1, attack: 1, health: 1, speed: 1 } });
    r = await api('/api/art/generate', { type: 'card', id: 'apitest_noart', prompt: 'x', useRef: true });
    check('useRef with no art rejected', r.status !== 200 && /no current art/.test(r.data.error || ''), JSON.stringify(r.data));
    await api('/api/item/delete', { type: 'card', id: 'apitest_noart' });

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
