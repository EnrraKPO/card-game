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

for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map', 'data/render_filters', 'assets/cards/enemies', 'assets/relics', 'assets/abilities', 'assets/ui/shaders'])
  fs.mkdirSync(path.join(SANDBOX, d), { recursive: true });
// render-filter validation checks the shader actually exists in the project, so the sandbox
// needs a real file at the res:// path the tests use.
fs.writeFileSync(path.join(SANDBOX, 'assets/ui/shaders/filter_glow.gdshader'), 'shader_type canvas_item;\n');
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
    check('vocab exposes composition vocabularies', Array.isArray(r.data.vocab.elements) && Array.isArray(r.data.vocab.pieces));

    // ── save NEW entries into a chosen (fresh) file ──
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_zap', display_name: 'Zap', cost: 1, attack: 2, health: 2, speed: 3 } });
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
      id: 'apitest_bad', display_name: 'B', cost: 1, attack: 1, health: 1, speed: 'fast' } });
    check('invalid entry rejected', r.status === 400 && /missing stat "speed"/.test(r.data.error), r.data.error);
    // ── the deleted effect schema is REFUSED at the gate (effect-cleanse 2026-08-11) ──
    // An EMPTY effects array is the post-strip save shape and passes silently; authored
    // content is the old language and must not flow back into data/ through the Tool.
    const OLD_FX = [{ trigger: { kind: 'event', event: 'play' }, targets: { kind: 'self' }, attribute: 'attack', amount: 1 }];
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_oldfx', display_name: 'O', cost: 1, attack: 1, health: 1, speed: 1, effects: OLD_FX } });
    check('card with authored effects refused', r.status === 400 && /deleted schema/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_emptyfx', display_name: 'E', cost: 1, attack: 1, health: 1, speed: 1, effects: [] } });
    check('card with an EMPTY effects array saves (post-strip shape)', r.status === 200, JSON.stringify(r.data).slice(0, 200));
    await api('/api/game/delete-entry', { type: 'card', id: 'apitest_emptyfx' });
    // The NEW schema (signed ATTACK_SYSTEM_DESIGN.html): named-effect references and
    // native inline effects flow through the Tool — the phase-3 authoring contract.
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_newfx', display_name: 'N', cost: 1, attack: 1, health: 1, speed: 1,
      effects: ['melee_attack', { trigger: { kind: 'event', event: 'act', of: 'self' },
        targets: { kind: 'nearest' }, payloads: [{ kind: 'attack', amount: 3 }] }] } });
    check('card with new-schema effects (reference + inline) saves', r.status === 200, JSON.stringify(r.data).slice(0, 200));
    await api('/api/game/delete-entry', { type: 'card', id: 'apitest_newfx' });
    r = await api('/api/game/save', { type: 'status', file: 'apitest_statuses.json', data: {
      id: 'apitest_oldstatus', effects: OLD_FX } });
    check('status with authored effects refused', r.status === 400 && /deleted schema/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'relic', file: 'apitest_relics.json', data: {
      id: 'apitest_shell_relic', display_name: 'Shell', description: 'the re-authoring brief' } });
    check('an effect-less relic SHELL saves (the brief is the content)', r.status === 200, JSON.stringify(r.data).slice(0, 200));
    await api('/api/game/delete-entry', { type: 'relic', id: 'apitest_shell_relic' });
    r = await api('/api/game/save', { type: 'relic', file: 'apitest_relics.json', data: {
      id: 'apitest_oldrelic', display_name: 'R', effects: OLD_FX } });
    check('relic with authored effects refused', r.status === 400 && /deleted schema/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'charm', file: 'apitest_charms.json', data: {
      id: 'apitest_oldcharm', display_name: 'C', effects: OLD_FX } });
    check('charm with authored effects refused', r.status === 400 && /deleted schema/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'upgrade', file: 'apitest_upgrades.json', data: {
      id: 'apitest_oldtree', display_name: 'T', nodes: [{ id: 'n1', display_name: 'N', effects: OLD_FX }] } });
    check('upgrade node with authored effects refused', r.status === 400 && /deleted schema/.test(r.data.error), r.data.error);
    // the spread mechanism is deleted from the game (disavowed 2026-08-11) — the key is
    // refused whole, whatever its shape.
    r = await api('/api/game/save', { type: 'status', file: 'apitest_statuses.json', data: {
      id: 'apitest_wildfire', decay: 'none', stacking: 'stack',
      spread: { phase: 'turn_start', chance: 0.2, decay_chance: 0.4 } } });
    check('spread block refused (deleted mechanism)', r.status === 400 && /'spread' is deleted/.test(r.data.error), r.data.error);

    // ── the OLD named-effects keyword tier was deleted whole (2026-08-12, attack rebuild
    // total cleanse) — the type no longer exists; the NEW library is data/effects/ ──
    r = await api('/api/game/save', { type: 'namedeffect', file: 'apitest_named.json', data: {
      id: 'apitest_burn', display_name: 'Burn', description: 'Deal 1 damage.' } });
    check('namedeffect type is gone', r.status === 400, JSON.stringify(r.data).slice(0, 120));
    // the innate-rules tier was KILLED whole (2026-08-11 ruling) — the type no longer exists
    r = await api('/api/game/save', { type: 'innate', file: 'apitest_innate.json', data: {
      id: 'apitest_scorch', display_name: 'Scorch' } });
    check('innate type is gone', r.status === 400, JSON.stringify(r.data).slice(0, 120));
    // ability: the costume's combat half is gone too — autocast/material refused
    r = await api('/api/game/save', { type: 'ability', file: 'apitest_abilities.json', data: {
      id: 'apitest_shell_ability', display_name: 'Shout', cost: { mana: 1, tap: true } } });
    check('an effect-less ability SHELL saves', r.status === 200, JSON.stringify(r.data).slice(0, 200));
    await api('/api/game/delete-entry', { type: 'ability', id: 'apitest_shell_ability' });
    r = await api('/api/game/save', { type: 'ability', file: 'apitest_abilities.json', data: {
      id: 'apitest_oldability', cost: { mana: 1 }, autocast: true } });
    check('ability autocast refused', r.status === 400 && /'autocast' is the deleted schema/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'ability', file: 'apitest_abilities.json', data: {
      id: 'apitest_oldability2', cost: { mana: 1 }, effects: OLD_FX } });
    check('ability with authored effects refused', r.status === 400 && /deleted schema/.test(r.data.error), r.data.error);

    // ── enemy-engine authoring handles: card role + encounter survival_weights ──
    // These are the dials the CPU actually reads (BoardScoring). The Tool used to drop
    // them on save, silently un-tuning an encounter — every check here guards that.
    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_dummy', display_name: 'Dummy', cost: 1, attack: 1, health: 2, speed: 2,
      enemy_only: true, role: 'fodder' } });
    check('card role saves', r.status === 200, JSON.stringify(r.data));
    check('role persisted', readSbox('data/cards/apitest_units.json').find(e => e.id === 'apitest_dummy').role === 'fodder');

    const enc = { id: 'apitest_gym', node_type: 'test', enemy_king: 'pawn',
      enemy_pool: [{ id: 'apitest_dummy', weight: 1 }], pick_count: [4, 4],
      survival_weights: { fodder: 0.5, captain: 1.0, apitest_dummy: 0 } };
    r = await api('/api/game/save', { type: 'encounter', file: 'apitest_encounters.json', data: enc });
    check('test node_type accepted', r.status === 200, JSON.stringify(r.data));
    const savedEnc = () => readSbox('data/encounters/apitest_encounters.json').find(e => e.id === 'apitest_gym');
    check('survival_weights persisted whole', JSON.stringify(savedEnc().survival_weights) === JSON.stringify({ fodder: 0.5, captain: 1.0, apitest_dummy: 0 }));
    check('a zero weight survives (0 = "protect this not at all")', savedEnc().survival_weights.apitest_dummy === 0);

    r = await api('/api/game/save', { type: 'encounter', file: 'apitest_encounters.json', data: { ...enc, node_type: 'skirmish' } });
    check('unknown node_type still rejected', r.status === 400 && /node_type must be/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'encounter', file: 'apitest_encounters.json', data: { ...enc, survival_weights: { fodder: 'lots' } } });
    check('non-numeric survival weight rejected', r.status === 400 && /must be a number/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'encounter', file: 'apitest_encounters.json', data: { ...enc, survival_weights: { fodder: -1 } } });
    check('negative survival weight rejected', r.status === 400 && /must be a number/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'encounter', file: 'apitest_encounters.json', data: { ...enc, survival_weights: [0.5] } });
    check('array survival_weights rejected', r.status === 400 && /object of weight entries/.test(r.data.error), r.data.error);
    r = await api('/api/game/save', { type: 'encounter', file: 'apitest_encounters.json', data: { ...enc, enabled: false } });
    check('encounter enabled:false persisted', r.status === 200 && savedEnc().enabled === false, JSON.stringify(r.data));

    r = await api('/api/game/save', { type: 'card', file: 'apitest_units.json', data: {
      id: 'apitest_dummy', display_name: 'Dummy', cost: 1, attack: 1, health: 2, speed: 2,
      enemy_only: true, role: 'wizard' } });
    check('unknown role rejected', r.status === 400 && /bad role "wizard"/.test(r.data.error), r.data.error);

    // ── tagging a whole set at once (the enemy hub's ≡ Bulk) ──
    for (const c of [
      { id: 'roletest_a', display_name: 'RA', cost: 1, attack: 1, health: 2, speed: 2, enemy_only: true },
      { id: 'roletest_b', display_name: 'RB', cost: 1, attack: 1, health: 2, speed: 2, enemy_only: true, role: 'dps' },
      { id: 'roletest_king', display_name: 'RK', cost: 0, attack: 1, health: 9, speed: 2, enemy_only: true, is_king: true },
    ]) await api('/api/game/save', { type: 'card', file: 'roletest_units.json', data: c });
    const roleIds = ['roletest_a', 'roletest_b', 'roletest_king'];
    const roleById = id => readSbox('data/cards/roletest_units.json').find(e => e.id === id);

    r = await api('/api/game/bulk', { type: 'card', ids: roleIds, ops: [{ kind: 'set_role', role: 'fodder' }] });
    check('bulk set_role tags the untagged and retags the tagged, skipping the king',
      r.status === 200 && r.data.updated === 2 && r.data.skipped === 1, JSON.stringify(r.data));
    check('role written to both non-kings', roleById('roletest_a').role === 'fodder' && roleById('roletest_b').role === 'fodder');
    check('a king never receives a role (is_king already reads as captain)', roleById('roletest_king').role === undefined);

    r = await api('/api/game/bulk', { type: 'card', ids: roleIds, ops: [{ kind: 'set_role', role: 'fodder' }] });
    check('bulk set_role is idempotent', r.data.updated === 0 && r.data.skipped === 3, JSON.stringify(r.data));

    r = await api('/api/game/bulk', { type: 'card', ids: ['roletest_a'], ops: [{ kind: 'set_role', role: '' }] });
    check('an empty role CLEARS the tag', r.data.updated === 1 && roleById('roletest_a').role === undefined);

    r = await api('/api/game/bulk', { type: 'card', ids: ['roletest_b'], ops: [{ kind: 'set_role', role: 'wizard' }] });
    check('bulk set_role refuses an unknown tag', r.data.updated === 0 && roleById('roletest_b').role === 'fodder');

    // the game tree must EXPOSE role/is_king — the enemy hub's tags are invisible otherwise
    r = await api('/api/state');
    const treeCard = id => r.data.game.card.find(c => c.id === id);
    check('game tree exposes the role tag', treeCard('roletest_b').role === 'fodder', JSON.stringify(treeCard('roletest_b')));
    check('game tree exposes is_king', treeCard('roletest_king').is_king === true);
    check('an untagged unit reports no role', treeCard('roletest_a').role === undefined);

    // ── bulk edits across a filtered set (set / pump / grant ability) ──
    for (const c of [
      { id: 'bulk_a', display_name: 'A', cost: 3, attack: 2, health: 2, speed: 3 },
      { id: 'bulk_b', display_name: 'B', cost: 1, attack: 2, health: 2, speed: 3 },
      { id: 'bulk_c', display_name: 'C', cost: 2, attack: 2, health: 2, speed: 3 },
    ]) await api('/api/game/save', { type: 'card', file: 'bulk_units.json', data: c });
    // a derived-stats composition card has no explicit cost — pump must skip it
    await api('/api/game/save', { type: 'card', file: 'bulk_units.json', data: {
      id: 'bulk_derived', display_name: 'D', _derive_stats: true, elements: ['fire'], chess_pieces: ['pawn', 'pawn'] } });
    const bulkIds = ['bulk_a', 'bulk_b', 'bulk_c', 'bulk_derived'];
    const bulkById = id => readSbox('data/cards/bulk_units.json').find(e => e.id === id);

    r = await api('/api/game/bulk', { type: 'card', ids: bulkIds, ops: [{ kind: 'pump', attr: 'cost', delta: -1 }] });
    check('bulk pump: 3 updated, 1 skipped (derived)', r.status === 200 && r.data.updated === 3 && r.data.skipped === 1, JSON.stringify(r.data));
    check('bulk pump decrements uneven values relatively', bulkById('bulk_a').cost === 2 && bulkById('bulk_c').cost === 1);
    check('bulk pump floors at 0 (1→0, never negative)', bulkById('bulk_b').cost === 0);
    check('bulk pump leaves derived-stats card untouched', bulkById('bulk_derived').cost === undefined);

    r = await api('/api/game/bulk', { type: 'card', ids: bulkIds, ops: [{ kind: 'set', attr: 'shield', value: 2 }] });
    check('bulk set writes the constant to every card', r.data.updated === 4 && ['bulk_a', 'bulk_b', 'bulk_c', 'bulk_derived'].every(id => bulkById(id).shield === 2));

    r = await api('/api/game/bulk', { type: 'card', ids: ['bulk_a', 'bulk_b'], ops: [{ kind: 'grant_ability', ability: 'zap_bolt' }] });
    check('bulk grant ability adds the id once', r.data.updated === 2 && bulkById('bulk_a').abilities.join() === 'zap_bolt');
    r = await api('/api/game/bulk', { type: 'card', ids: ['bulk_a'], ops: [{ kind: 'grant_ability', ability: 'zap_bolt' }] });
    check('bulk grant ability is idempotent (already present → skipped)', r.data.updated === 0 && r.data.skipped === 1 && bulkById('bulk_a').abilities.length === 1);

    // the grant_effect op died with the effect layer — an unknown op is a per-entry error
    r = await api('/api/game/bulk', { type: 'card', ids: ['bulk_a'], ops: [{ kind: 'grant_effect',
      effect: { trigger: { kind: 'event', event: 'play' }, targets: { kind: 'self' }, attribute: 'attack', amount: 1 } }] });
    check('bulk grant_effect op is gone (unknown op errors, nothing written)',
      r.status === 200 && r.data.updated === 0 && (r.data.errors || []).length === 1
      && /unknown bulk op/.test(r.data.errors[0].error) && !(bulkById('bulk_a').effects || []).length, JSON.stringify(r.data));
    for (const id of bulkIds) await api('/api/game/delete-entry', { type: 'card', id });

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
      JSON.stringify({ id: 'apitest_tree', display_name: 'T', nodes: [{ id: 'n1', display_name: 'N' }] }));
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
    check('uploaded ref bypasses the own-art requirement',
      (r.data.error || '') !== 'this item has no installed art to use as input',
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
    check('game-art ref bypasses the own-art requirement',
      (r.data.error || '') !== 'this item has no installed art to use as input', r.data.error);
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
    // vision analysis of the item's INSTALLED (deployed) art → a recreating prompt.
    // "Match art" always reads the deployed art, never a workspace draft, so give apitest_flip
    // installed art here (its workspace draft from /api/art/put above is deliberately ignored).
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/apitest_flip.png'), PNG1x1);
    r = await api('/api/art/prompt-from-art', { type: 'card', id: 'apitest_flip' });
    check('prompt-from-art analyzes the installed art',
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
    check('prompt-from-art without art rejected', r.status === 400 && /no installed game art/.test(r.data.error || ''));
    fakeOllama.close();

    // ── ✨ effects-from-words died with the effect layer (2026-08-11): endpoint gone ──
    r = await api('/api/effects/from-text', { type: 'card', text: '+1 strength to all pawn units' });
    check('effects-from-text endpoint is gone', r.status === 404, JSON.stringify(r.data).slice(0, 120));

    // ── 💬 edit chat: ops plan → simulate + validate → preview → apply ──
    const chatReqs = []; let chatQueue = [];
    const fakeChat = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        chatReqs.push(JSON.parse(b));
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ response: chatQueue.shift() || '{}' }));
      });
    });
    await new Promise(ok => fakeChat.listen(8485, ok));
    await api('/api/settings', { ollamaUrl: 'http://127.0.0.1:8485', chatModel: 'chatmodel' });
    await api('/api/game/save', { type: 'card', file: 'chattest_units.json', data: {
      id: 'chat_pawn_a', display_name: 'Chat Pawn A', cost: 1, attack: 1, health: 2, speed: 3, chess_pieces: ['pawn'] } });
    await api('/api/game/save', { type: 'card', file: 'chattest_units.json', data: {
      id: 'chat_pawn_b', display_name: 'Chat Pawn B', cost: 1, attack: 1, health: 2, speed: 3, chess_pieces: ['pawn'] } });
    // a full blanket edit: one op across both pawns + one single-pawn op
    chatQueue = ['<think>ok</think>```json\n' + JSON.stringify({ reply: 'Done.', ops: [
      { type: 'card', ids: ['chat_pawn_a', 'chat_pawn_b'], op: 'set', field: 'cost', value: 2 },
      { type: 'card', ids: ['chat_pawn_b'], op: 'set', field: 'speed', value: 5 },
    ] }) + '\n```'];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'all chat pawns cost 2' }] });
    const proposal = r.data;
    check('chat returns a validated preview', r.status === 200 && proposal.ok && proposal.attempts === 1
      && proposal.reply === 'Done.' && proposal.changes.length === 2, JSON.stringify(r.data).slice(0, 400));
    const chA = proposal.changes.find(c => c.id === 'chat_pawn_a'), chB = proposal.changes.find(c => c.id === 'chat_pawn_b');
    check('preview carries before/after + notes', chA.before.cost === 1 && chA.after.cost === 2
      && chB.after.speed === 5 && chA.notes.some(n => /cost: 1 → 2/.test(n))
      && chB.notes.some(n => /speed: 3 → 5/.test(n)), JSON.stringify({ a: chA.notes, b: chB.notes }));
    check('preview writes NOTHING to game files', readSbox('data/cards/chattest_units.json')[0].cost === 1);
    let chatReq = chatReqs[chatReqs.length - 1];
    check('chat request: model + ops grammar + effects refusal + catalog + conversation',
      chatReq.model === 'chatmodel' && /"set"\|"delete"\|"append"\|"remove"/.test(chatReq.system)
      && /Never write an "effects" field/.test(chatReq.system)
      && /- chat_pawn_a: .*cost=1/.test(chatReq.prompt) && /Designer: all chat pawns cost 2/.test(chatReq.prompt));

    // an ops plan that writes the deleted effect schema fails validation every retry —
    // the chat physically cannot reinstall the old language
    const FX_OP = JSON.stringify({ reply: 'x', ops: [{ type: 'card', ids: ['chat_pawn_a'], op: 'append',
      field: 'effects', value: { trigger: { kind: 'event', event: 'play' }, targets: { kind: 'self' }, attribute: 'attack', amount: 1 } }] });
    chatQueue = [FX_OP, FX_OP, FX_OP, FX_OP, FX_OP, FX_OP];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'x' }] });
    check('chat cannot append the deleted effect schema',
      r.data.ok && r.data.changes.length === 0 && /deleted schema/.test(r.data.warning || ''), JSON.stringify(r.data).slice(0, 300));

    // a pure chat answer proposes nothing
    chatQueue = [JSON.stringify({ reply: 'You have two chat pawns.', ops: [] })];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'how many chat pawns?' }] });
    check('pure chat answer has no changes', r.data.ok && r.data.reply === 'You have two chat pawns.' && r.data.changes.length === 0);

    // "need" fetches full entry JSON, then ops arrive on the next generation
    chatQueue = [JSON.stringify({ reply: '', need: [{ type: 'card', ids: ['chat_pawn_a'] }] }),
      JSON.stringify({ reply: 'ok', ops: [{ type: 'card', ids: ['chat_pawn_a'], op: 'set', field: 'speed', value: 4 }] })];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'x' }] });
    check('need loop feeds full JSON then accepts ops', r.data.attempts === 2 && r.data.changes[0].after.speed === 4
      && chatReqs[chatReqs.length - 1].prompt.includes('"display_name":"Chat Pawn A"'), JSON.stringify(r.data).slice(0, 300));

    // a broken op is retried with the error fed back
    chatQueue = [JSON.stringify({ reply: 'x', ops: [{ type: 'card', ids: ['nope'], op: 'set', field: 'cost', value: 2 }] }),
      JSON.stringify({ reply: 'fixed', ops: [{ type: 'card', ids: ['chat_pawn_a'], op: 'set', field: 'cost', value: 2 }] })];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'x' }] });
    check('bad op retries with the failure fed back', r.data.attempts === 2 && r.data.reply === 'fixed'
      && chatReqs[chatReqs.length - 1].prompt.includes('no card "nope"'), JSON.stringify(r.data).slice(0, 300));

    // a result that fails validateItem is retried; persistent failure returns NO changes
    const BAD_OP = JSON.stringify({ reply: 'x', ops: [{ type: 'card', ids: ['chat_pawn_a'], op: 'delete', field: 'cost' }] });
    chatQueue = [BAD_OP, BAD_OP, BAD_OP, BAD_OP, BAD_OP, BAD_OP];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'x' }] });
    check('persistently invalid plan yields warning and no changes',
      r.data.ok && r.data.changes.length === 0 && /missing stat "cost"/.test(r.data.warning || ''), JSON.stringify(r.data).slice(0, 300));
    check('validator error was fed back to the model',
      chatReqs[chatReqs.length - 1].prompt.includes('missing stat "cost"'));

    r = await api('/api/chat/edit', { messages: [] });
    check('empty chat rejected', r.status === 400);

    // apply the first proposal: entries write through the normal edit machinery
    r = await api('/api/chat/apply', { changes: proposal.changes });
    check('apply writes both entries', r.data.ok && r.data.applied.length === 2 && r.data.skipped.length === 0, JSON.stringify(r.data));
    let chatFile = readSbox('data/cards/chattest_units.json');
    check('applied values landed', chatFile[0].cost === 2 && chatFile[1].cost === 2 && chatFile[1].speed === 5);
    r = await api('/api/game/item?type=card&id=chat_pawn_a');
    check('applied entry is a recorded (revertible) edit', r.data.edited === true);

    // re-applying the SAME preview is refused: the entries changed since it was taken
    r = await api('/api/chat/apply', { changes: proposal.changes });
    check('stale preview refused per entry', !r.data.ok && r.data.applied.length === 0
      && r.data.skipped.length === 2 && /changed since this preview/.test(r.data.skipped[0].error), JSON.stringify(r.data));

    // revert rides the normal edit records: an entry the tool ADDED reverts by removal…
    r = await api('/api/game/restore', { type: 'card', id: 'chat_pawn_a' });
    check('reverting a chat edit on a tool-added entry removes it',
      r.status === 200 && !readSbox('data/cards/chattest_units.json').some(e => e.id === 'chat_pawn_a'));
    // …and a PRE-EXISTING entry reverts to its original values
    r = await api('/api/game/item?type=card&id=pawn');
    const pawnBefore = r.data.data;
    const pawnAfter = JSON.parse(JSON.stringify(pawnBefore));
    pawnAfter.cost = 2;
    r = await api('/api/chat/apply', { changes: [{ type: 'card', id: 'pawn', file: 'base.json', before: pawnBefore, after: pawnAfter }] });
    check('chat apply works on pre-existing entries', r.data.ok && r.data.applied.length === 1, JSON.stringify(r.data));
    check('pre-existing entry updated', readSbox('data/cards/base.json').find(e => e.id === 'pawn').cost === 2);
    r = await api('/api/game/restore', { type: 'card', id: 'pawn' });
    check('chat edit reverts like any edit', r.status === 200
      && readSbox('data/cards/base.json').find(e => e.id === 'pawn').cost === 1);

    // ── create: a brand-new entry, referenced by a later op in the SAME plan ──
    const RAGE = { id: 'chat_rage', display_name: 'Chat Rage', cost: { mana: 1, tap: true } };
    chatQueue = [JSON.stringify({ reply: 'Created.', ops: [
      { type: 'ability', op: 'create', id: 'chat_rage', file: 'chattest_abilities.json', value: RAGE },
      { type: 'card', ids: ['chat_pawn_b'], op: 'append', field: 'abilities', value: 'chat_rage' },
    ] })];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'give pawn b a new heal ability' }] });
    const createProposal = r.data;
    const created = (createProposal.changes || []).find(c => c.id === 'chat_rage');
    check('create previews a new entry', createProposal.ok && created && created.created === true
      && created.before === null && created.file === 'chattest_abilities.json'
      && created.notes.some(n => n.startsWith('display_name:')), JSON.stringify(createProposal).slice(0, 300));
    check('preview writes NO new file', !fs.existsSync(path.join(SANDBOX, 'data/abilities/chattest_abilities.json')));
    check('system prompt teaches the create op', /"op": "create"/.test(chatReqs[chatReqs.length - 1].system)
      && /files: /.test(chatReqs[chatReqs.length - 1].prompt));

    r = await api('/api/chat/apply', { changes: createProposal.changes });
    check('apply writes the created entry and its reference', r.data.ok && r.data.applied.length === 2, JSON.stringify(r.data));
    check('created ability landed in its chosen file', readSbox('data/abilities/chattest_abilities.json')[0].id === 'chat_rage');
    check('card gained the new ability id',
      readSbox('data/cards/chattest_units.json').find(e => e.id === 'chat_pawn_b').abilities[0] === 'chat_rage');

    // re-applying the same create is refused — the id exists now
    r = await api('/api/chat/apply', { changes: [created] });
    check('stale create refused once the id exists', !r.data.ok && /appeared since/.test(r.data.skipped[0].error), JSON.stringify(r.data));

    // a create with a taken id is retried with the error fed back
    chatQueue = [JSON.stringify({ reply: 'x', ops: [{ type: 'ability', op: 'create', id: 'chat_rage', file: 'x.json', value: RAGE }] }),
      JSON.stringify({ reply: 'ok', ops: [] })];
    r = await api('/api/chat/edit', { messages: [{ role: 'user', content: 'x' }] });
    check('duplicate-id create retried with the failure fed back', r.data.attempts === 2
      && chatReqs[chatReqs.length - 1].prompt.includes('already exists'), JSON.stringify(r.data).slice(0, 300));

    // revert rides the normal `added` record: the created entry is removed again
    r = await api('/api/game/restore', { type: 'ability', id: 'chat_rage' });
    check('reverting a chat-created entry removes it (file emptied → gone)',
      r.status === 200 && !fs.existsSync(path.join(SANDBOX, 'data/abilities/chattest_abilities.json')));

    await api('/api/game/delete-entry', { type: 'card', id: 'chat_pawn_b' });
    fakeChat.close();
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

    // ── render filters: a new content type whose params are arbitrary shader uniforms ──
    const SHADER = 'res://assets/ui/shaders/filter_glow.gdshader';
    r = await api('/api/game/save', { type: 'render_filter', file: 'filters.json', data: {
      id: 'apitest_glow', display_name: 'Test Glow', shader: SHADER, pad: 72, layer: 'behind',
      params: { glow_color: 'ffa51e', spread: 46, falloff: 2 },
      concept: 'c', explanation: 'e' } });
    check('render filter saves', r.status === 200 && r.data.action === 'added', JSON.stringify(r.data));
    let rf = readSbox('data/render_filters/filters.json');
    check('render filter round-trips params verbatim', rf[0].params.glow_color === 'ffa51e'
      && rf[0].params.spread === 46 && rf[0].layer === 'behind', JSON.stringify(rf[0]));
    check('render filter appears in state tree', (await api('/api/state')).data.game.render_filter
      .some(x => x.id === 'apitest_glow'));
    check('render filter ids exposed as vocab', (await api('/api/state')).data.vocab.renderFilters
      .some(x => x.id === 'apitest_glow'));
    check('shaders exposed as vocab', (await api('/api/state')).data.vocab.shaders
      .some(x => x.id === SHADER));

    const badFilter = (over, label, rx) => api('/api/game/save', { type: 'render_filter', file: 'filters.json',
      data: Object.assign({ id: 'apitest_bad_filter', display_name: 'B', shader: SHADER, pad: 72,
        layer: 'behind', params: {}, concept: 'c', explanation: 'e' }, over) })
      .then(res => check(label, res.status === 400 && rx.test(res.data.error || ''), res.data.error));
    await badFilter({ shader: 'res://nope.gdshader' }, 'missing shader file rejected', /does not exist/);
    await badFilter({ shader: 'assets/x.png' }, 'non-shader path rejected', /res:\/\/.*gdshader/);
    await badFilter({ layer: 'sideways' }, 'unknown layer rejected', /layer must be one of/);
    await badFilter({ pad: -3 }, 'negative pad rejected', /pad must be/);
    // The invariant that actually bites: the effect renders into a quad padded by `pad`, so a
    // wider spread is silently clipped rather than drawn.
    await badFilter({ pad: 20, params: { spread: 46 } }, 'spread wider than pad rejected', /exceeds pad/);
    await badFilter({ params: { 'Glow Color': 'ffa51e' } }, 'non-uniform param key rejected', /uniform name/);
    // …but an INWARD filter (inner glow) legitimately declares pad 0 and spreads into the
    // silhouette, where there is no quad edge to clip against.
    r = await api('/api/game/save', { type: 'render_filter', file: 'filters.json', data: {
      id: 'apitest_inner', display_name: 'Test Inner', shader: SHADER, pad: 0, layer: 'above',
      params: { spread: 26 }, concept: 'c', explanation: 'e' } });
    check('inward filter (pad 0) accepts a spread', r.status === 200, JSON.stringify(r.data));
    await badFilter({ params: { glow_color: 'nothex' } }, 'non-number non-colour param rejected', /number or a 6-digit hex/);

    // A VFX entry on renderer "filter" must keep its arbitrary uniform params — the procedural
    // whitelist would otherwise strip them on save.
    fs.mkdirSync(path.join(SANDBOX, 'data/vfx'), { recursive: true });
    r = await api('/api/game/save', { type: 'vfx', file: 'vfx.json', data: {
      id: 'apitest_filter_cue', display_name: 'Filter Cue', category: 'ui', renderer: 'filter',
      behavior: 'glow', sustained: true, placeholder: false,
      params: { filter: 'apitest_glow', glow_color: 'ffa51e', spread: 46,
        animate: { param: 'intensity', from: 0.5, to: 1.2, period: 1.6 } },
      concept: 'c', explanation: 'e', prompt: 'p' } });
    check('vfx renderer "filter" accepted', r.status === 200, JSON.stringify(r.data));
    const vfxRow = readSbox('data/vfx/vfx.json')[0];
    check('filter vfx keeps its uniform params + animate block',
      vfxRow.params.filter === 'apitest_glow' && vfxRow.params.spread === 46
      && vfxRow.params.animate.param === 'intensity', JSON.stringify(vfxRow.params));

    // ── ✨ recipe inference: concept from piece-relatives, theme from element-relatives ──
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_kin_lib.json'), JSON.stringify([
      { id: 'bishop_rook', display_name: 'Bishop Rook', cost: 2, attack: 2, health: 4, speed: 2,
        chess_pieces: ['bishop', 'rook'], tool: { art: { prompt: 'a mitred tower-warden construct' } } },
      { id: 'darkness_earth_pawn', display_name: 'Dark Earth Pawn', cost: 1, attack: 1, health: 2, speed: 3,
        elements: ['darkness', 'earth'], chess_pieces: ['pawn'],
        // a distinctive AUTHORING prompt: the old system rode this verbatim into every
        // theme-mate's inference (the earth_earth darkness leak). A frozen canonical ref
        // must NEVER surface it — the theme look comes from an art-derived caption instead.
        tool: { art: { prompt: 'CONTAMINATION_PROBE obsidian void violet twilight' } } },
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
    // Canonical refs are appointed explicitly now (no per-read auto-seeding): the seed
    // endpoint SNAPSHOTS the default cards' art into frozen workspace assets (snap_<id>.png),
    // severing the game link. concept bishop_rook ← bishop_rook.png; theme darkness_earth ←
    // darkness_earth_pawn.png (darkness_earth_knight has no art, so it is not appointed).
    await api('/api/art-guides/seed', { axis: 'concept', key: 'bishop_rook' });
    await api('/api/art-guides/seed', { axis: 'theme', key: 'darkness_earth' });
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook' });
    check('kin inference anchors on the concept asset (frozen snapshot, same-concept default)',
      r.data.ok && r.data.prompt === KIN_PROMPT
      && r.data.ref && r.data.ref.source === 'upload' && r.data.ref.path === 'snap_bishop_rook.png'
      && r.data.inferredFrom.anchor === 'snap_bishop_rook.png'
      && r.data.inferredFrom.theme.includes('snap_darkness_earth_pawn.png')
      && r.data.stats.mode === 'concept', JSON.stringify(r.data));
    check('concept mode carries the CONCEPT and frees the presentation',
      kinReq && kinReq.prompt.includes('Reference image 1 is THE CONCEPT')
      && /Identify the CONCEPT of reference image 1/.test(kinReq.prompt)
      && /NEW VERSION of that concept/.test(kinReq.prompt)
      // the AUTHORED name rides in (concept + theme identity), but the composition-encoding
      // id never appears — the theme look enters as an ANONYMOUS art-derived caption
      && /Card name .*: Grave Bastion/.test(kinReq.prompt)
      && /theme example \d+: "/.test(kinReq.prompt)
      && !/Composition:/.test(kinReq.prompt)
      && !/bishop_rook|darkness_earth/.test(kinReq.prompt)
      // image 1 is the concept anchor; the theme is described by caption, not shown
      && (kinReq.images || []).length === 1, kinReq && kinReq.prompt);
    check('a theme card\'s AUTHORING prompt never leaks into inference (the earth_earth fix)',
      kinReq && !/CONTAMINATION_PROBE/.test(kinReq.prompt), kinReq && kinReq.prompt);
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'replicate' });
    check('replicate mode carries the PICTURE (re-dress only)',
      r.data.ok && r.data.stats.mode === 'replicate'
      && /re-dress it in the theme shown by the examples/.test(kinReq.prompt)
      && /SAME illustration, re-themed/.test(kinReq.prompt)
      && !/darkness and earth/.test(kinReq.prompt), kinReq && kinReq.prompt);   // no element naming
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('free adherence keeps the blend behavior (concept + theme, art-derived captions)',
      r.data.ok && r.data.stats.mode === 'free'
      && /CONCEPT references/.test(kinReq.prompt)
      && /concept reference \d+[^\n]*: "/.test(kinReq.prompt)   // caption text, not a card's prompt
      && /Card name .*: Grave Bastion/.test(kinReq.prompt)   // authored name present
      && !/CONTAMINATION_PROBE/.test(kinReq.prompt)   // theme card's authoring prompt stays out
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
      && readSbox('data/cards/apitest_kin.json').find(e => e.id === 'darkness_earth_bishop_rook').tool.art.ref.path === 'snap_bishop_rook.png'
      && readSbox('data/cards/apitest_kin.json').find(e => e.id === 'darkness_earth_knight').tool.art.prompt === 'already authored');
    check('running jobs surface in state for UI reattachment',
      Array.isArray((await api('/api/state')).data.inferJobs));
    // adherence threads through the BATCH too (the bulk path is the primary use)
    fs.writeFileSync(path.join(SANDBOX, 'data/cards/apitest_kin2.json'), JSON.stringify([
      { id: 'darkness_earth_rook', display_name: 'Grave Turret', cost: 3, attack: 2, health: 9, speed: 1,
        elements: ['darkness', 'earth'], chess_pieces: ['rook'] }]));
    // own art → anchors on itself (concept 'rook' isn't appointed); theme darkness_earth is
    fs.writeFileSync(path.join(SANDBOX, 'assets/cards/darkness_earth_rook.png'), PNG1x1);
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

    // ── feature 2: anchor-mode toggles (global settings) ──
    // darkness_earth_pawn HAS installed (deployed) art, so 'installed' mode anchors on it
    // (ref.source 'installed'); 'canonical' mode ignores own art (anchor = the appointed concept).
    r = await api('/api/settings', { kinAnchorMode: 'installed' });
    check('kinAnchorMode installed persists', r.data.settings.kinAnchorMode === 'installed');
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_pawn' });
    check('anchor mode installed: own-art card anchors on its deployed art',
      r.data.ref && r.data.ref.source === 'installed', JSON.stringify(r.data.ref));
    r = await api('/api/settings', { kinAnchorMode: 'canonical' });
    check('kinAnchorMode canonical persists', r.data.settings.kinAnchorMode === 'canonical');
    r = await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_pawn' });
    check('anchor mode canonical: own art skipped (anchor is the appointed concept, not the card)',
      !r.data.ref || r.data.ref.source !== 'installed', JSON.stringify(r.data.ref));
    check('legacy kinAnchorMode "current" migrates to installed',
      (await api('/api/settings', { kinAnchorMode: 'current' })).data.settings.kinAnchorMode === 'installed');
    check('bad kinAnchorMode rejected', (await api('/api/settings', { kinAnchorMode: 'bogus' })).status === 400);
    await api('/api/settings', { kinAnchorMode: 'installed' });

    // theme mode 'select' REPLACES the auto element-family theme with the hand-picked refs
    await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('theme mode family: the auto element-relative theme is used',
      /already authored/.test(kinReq.prompt), kinReq && kinReq.prompt);
    r = await api('/api/settings', { kinThemeMode: 'select', kinThemeRefs: ['bishop_rook'] });
    check('kinThemeMode + kinThemeRefs persist',
      r.data.settings.kinThemeMode === 'select' && r.data.settings.kinThemeRefs.includes('bishop_rook'));
    await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('theme mode select: picked refs REPLACE the family theme',
      /theme relative \d+: "a mitred tower-warden construct"/.test(kinReq.prompt)
      && !/already authored/.test(kinReq.prompt), kinReq && kinReq.prompt);
    check('bad kinThemeMode rejected', (await api('/api/settings', { kinThemeMode: 'bogus' })).status === 400);
    await api('/api/settings', { kinThemeMode: 'family', kinThemeRefs: [] });

    // ── feature 3: composition-keyed art guides (opt-in) ──
    // darkness_earth_bishop_rook → concept key "bishop_rook", theme key "darkness_earth".
    r = await api('/api/art-guides', {   // POST replaces the table; keys normalize to sorted order
      concept: { rook_bishop: { label: 'Warden', positive: 'a stone golem warden', negative: 'no exposed flesh' } },
      theme: { earth_darkness: { label: 'Gravebound', positive: 'deep violet basalt palette', negative: 'not bright, not stormy' } },
    });
    check('art-guides POST normalizes composition keys to sorted order',
      r.data.ok && !!r.data.guides.concept.bishop_rook && !!r.data.guides.theme.darkness_earth, JSON.stringify(r.data.guides));
    check('art-guides GET round-trips',
      (await api('/api/art-guides')).data.guides.concept.bishop_rook.positive === 'a stone golem warden');
    await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('art guides withheld when useArtGuides is off',
      !/stone golem warden/.test(kinReq.prompt), kinReq && kinReq.prompt);
    r = await api('/api/settings', { useArtGuides: true });
    check('useArtGuides persists', r.data.settings.useArtGuides === true);
    await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('art guides inject the authored concept + theme positives and the negatives',
      /AUTHORITATIVE.*a stone golem warden/.test(kinReq.prompt)
      && /deep violet basalt palette/.test(kinReq.prompt)
      && /Avoid — do NOT depict:.*no exposed flesh.*not bright/.test(kinReq.prompt), kinReq && kinReq.prompt);
    await api('/api/settings', { useArtGuides: false });
    await api('/api/art-guides', { concept: {}, theme: {} });

    // ── feature 4: always-on free-text steering (empty = inert) ──
    await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('steer withheld when empty', !/Creative direction/.test(kinReq.prompt), kinReq && kinReq.prompt);
    r = await api('/api/settings', { kinSteer: 'lit by a single amber lantern' });
    check('kinSteer persists', r.data.settings.kinSteer === 'lit by a single amber lantern');
    await api('/api/art/infer-recipe', { type: 'card', id: 'darkness_earth_bishop_rook', adherence: 'free' });
    check('steer injects a creative-direction line into the prompt',
      /Creative direction \(follow this\): lit by a single amber lantern/.test(kinReq.prompt), kinReq && kinReq.prompt);
    await api('/api/settings', { kinSteer: '' });

    // ── overwrite: re-infer cards that already carry a recipe (default skips them) ──
    // Runs LAST — it overwrites darkness_earth_knight's authored prompt, which earlier
    // tests depend on. Both entries in apitest_kin.json now have recipes → both process.
    r = await api('/api/art/infer-recipes', { type: 'card', file: 'apitest_kin.json', overwrite: true });
    let owJob = null;
    for (let i = 0; i < 100; i++) {
      await new Promise(ok => setTimeout(ok, 100));
      owJob = (await api('/api/art/infer-job?id=' + r.data.jobId)).data;
      if (owJob.status !== 'running') break;
    }
    check('overwrite batch re-infers recipe-carrying cards (nothing skipped)',
      owJob.status === 'done' && owJob.total === 2 && !owJob.results.some(x => x.skipped), JSON.stringify(owJob));
    check('overwrite replaced the previously-authored recipe',
      readSbox('data/cards/apitest_kin.json').find(e => e.id === 'darkness_earth_knight').tool.art.prompt === KIN_PROMPT);
    // default (no overwrite) still skips authored entries
    r = await api('/api/art/infer-recipes', { type: 'card', file: 'apitest_kin.json' });
    for (let i = 0; i < 100; i++) {
      await new Promise(ok => setTimeout(ok, 100));
      owJob = (await api('/api/art/infer-job?id=' + r.data.jobId)).data;
      if (owJob.status !== 'running') break;
    }
    check('default batch still skips recipe-carrying cards',
      owJob.results.every(x => x.skipped) && owJob.total === 0, JSON.stringify(owJob));
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
