#!/usr/bin/env node
/*
 * CardGame Content Authoring Tool — server.
 *
 * Zero-dependency Node HTTP server. Serves the SPA in public/ and a JSON API:
 *   - workspace CRUD  (Tool/workspace/<type>/<id>.json — the authoring library)
 *   - install/uninstall into the game workspace (data/<dir>/tool_<type>_<id>.json
 *     + art copied to the game's by-convention asset path). Every file written into
 *     the game is recorded in Tool/workspace/installed.json so uninstall removes
 *     exactly those files and nothing else.
 *   - game vocabulary (existing card/status/ability/... ids scanned from data/)
 *   - ComfyUI art generation (Flux 2 dev workflow, async jobs, saved to workspace).
 *
 * Run:  node server.js [port]     (default 8460)
 * Env:  CARDGAME_ROOT overrides the game root (default: parent of this folder)
 *       used by the test-suite to point installs at a sandbox.
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const TOOL_ROOT = __dirname;
const GAME_ROOT = process.env.CARDGAME_ROOT || path.resolve(TOOL_ROOT, '..');
// Isolated test runs must NOT share the real workspace (authored drafts, installed.json,
// edits.json) with whatever sandbox game root they're pointed at — otherwise a test run's
// own bookkeeping overwrites or resets real tracking state. CARDGAME_WORKSPACE lets the test
// harness redirect this entirely; unset in normal use.
const WORKSPACE = process.env.CARDGAME_WORKSPACE || path.join(TOOL_ROOT, 'workspace');
const PUBLIC = path.join(TOOL_ROOT, 'public');
const PORT = parseInt(process.argv[2] || '8460', 10);

// ── content-type registry ────────────────────────────────────────────────────
// dataDir: where an installed item's JSON goes inside the game.
// artDir:  where installed art goes (null = the game has no art slot for this type;
//          art can still be generated as a workspace reference image).
// artW/artH: default ComfyUI canvas for this type. rembg: default background removal.
const TYPES = {
  card:       { label: 'Card',            dataDir: 'data/cards',      artDir: 'assets/cards',     artW: 1024, artH: 1536, rembg: false },
  relic:      { label: 'Relic',           dataDir: 'data/relics',     artDir: 'assets/relics',    artW: 1024, artH: 1024, rembg: true  },
  status:     { label: 'Status',          dataDir: 'data/statuses',   artDir: null,               artW: 512,  artH: 512,  rembg: true  },
  ability:    { label: 'Ability',         dataDir: 'data/abilities',  artDir: 'assets/abilities', artW: 1024, artH: 1024, rembg: true  },
  charm:      { label: 'Charm',           dataDir: 'data/charms',     artDir: null,               artW: 512,  artH: 512,  rembg: true  },
  upgrade:    { label: 'Upgrade Tree',    dataDir: 'data/upgrades',   artDir: null,               artW: 512,  artH: 512,  rembg: true  },
  encounter:  { label: 'Encounter',      dataDir: 'data/encounters', artDir: null,               artW: 1024, artH: 1024, rembg: false },
  nodeweights:{ label: 'Map Node Weights',dataDir: 'data/map',        artDir: null,               artW: 1024, artH: 1024, rembg: false },
};

// ── small fs helpers ─────────────────────────────────────────────────────────
function ensureDir(p) { fs.mkdirSync(p, { recursive: true }); }
function readJson(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return fallback; }
}
function writeJson(p, data) {
  ensureDir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + '\n', 'utf8');
}
function validId(id) { return typeof id === 'string' && /^[a-z0-9_]+$/.test(id); }

ensureDir(WORKSPACE);
for (const t of Object.keys(TYPES)) ensureDir(path.join(WORKSPACE, t));
ensureDir(path.join(WORKSPACE, 'art'));

// ── settings ─────────────────────────────────────────────────────────────────
const SETTINGS_PATH = path.join(WORKSPACE, 'settings.json');
function getSettings() {
  return Object.assign({
    comfyUrl: 'http://127.0.0.1:8187', artStyle: '', stylePresets: {},
    turboLora: 'Flux_2-Turbo-LoRA_comfyui.safetensors',  // the user's Flux 2 turbo LoRA
    turboSteps: 8, turboStrength: 1.0,
  }, readJson(SETTINGS_PATH, {}));
}

// ── installed manifest ───────────────────────────────────────────────────────
// { "<type>/<id>": { files: ["data/cards/tool_card_x.json", ...], at: iso } }
const MANIFEST_PATH = path.join(WORKSPACE, 'installed.json');
function getManifest() { return readJson(MANIFEST_PATH, {}); }
function setManifest(m) { writeJson(MANIFEST_PATH, m); }

// ── editing EXISTING game content (in place, with snapshot-based restore) ─────
// Any entry in the game's own data files can be opened, edited and applied back.
// The first apply snapshots the original entry (and any replaced art) into
// workspace/edits.json + workspace/edits_backup/, so "Restore original" is exact.
const EDITS_PATH = path.join(WORKSPACE, 'edits.json');
function getEdits() { return readJson(EDITS_PATH, {}); }
function setEdits(e) { writeJson(EDITS_PATH, e); }
function editBackupArt(type, id) { return path.join(WORKSPACE, 'edits_backup', type, id + '.png'); }
function editBackupFile(type, file) { return path.join(WORKSPACE, 'edits_backup', '_files', type, file + '.orig'); }

const crypto = require('crypto');
function fileHash(abs) { return crypto.createHash('sha1').update(fs.readFileSync(abs)).digest('hex'); }

// Game files are edited as parsed JSON and re-serialized with tabs (the repo style).
function writeGameJson(abs, data) {
  fs.writeFileSync(abs, JSON.stringify(data, null, '\t') + '\n', 'utf8');
}

// All entries of a type in the game's own files (tool-installed files excluded — those are
// workspace-managed). nodeweights files have no per-entry ids: each file is one pseudo-entry
// { id: <filename>, bands: [...] }.
function listGameEntries(type) {
  const dir = path.join(GAME_ROOT, TYPES[type].dataDir);
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.json') || f.startsWith('tool_')) continue;
    const raw = readJson(path.join(dir, f), null);
    if (raw == null) continue;
    if (type === 'nodeweights') {
      if (Array.isArray(raw)) out.push({ id: f.slice(0, -5), file: f, data: { id: f.slice(0, -5), bands: raw } });
      continue;
    }
    const entries = Array.isArray(raw) ? raw : [raw];
    for (const e of entries) if (e && e.id) out.push({ id: e.id, file: f, data: e });
  }
  return out;
}

function findGameEntry(type, id) {
  return listGameEntries(type).find(e => e.id === id) || null;
}

// Replace one entry inside its game file, preserving the file's single-object/array shape.
function replaceGameEntry(type, id, file, newData) {
  const abs = path.join(GAME_ROOT, TYPES[type].dataDir, file);
  const raw = readJson(abs, null);
  if (raw == null) throw new Error(`cannot parse ${file}`);
  if (type === 'nodeweights') {
    writeGameJson(abs, stripMeta(newData.bands || []));
    return;
  }
  const entry = stripMeta(newData);
  if (Array.isArray(raw)) {
    const i = raw.findIndex(e => e && e.id === id);
    if (i < 0) throw new Error(`entry "${id}" not found in ${file}`);
    raw[i] = entry;
    writeGameJson(abs, raw);
  } else {
    if (raw.id !== id) throw new Error(`entry "${id}" not found in ${file}`);
    writeGameJson(abs, entry);
  }
}

// Records what the tool just wrote to a game file on EVERY edit entry that shares that file —
// so a later restore's "untouched since our last write" hash check stays accurate no matter
// which sibling entry (of several sharing one file) is applied or restored, and in what order.
// Without this, a partial restore (done while siblings still hold edits) would silently write
// the file but leave siblings' recorded hashes stale, making the eventual LAST restore wrongly
// conclude the file was touched externally and fall back to a value-only rewrite that never
// recovers the original formatting.
function syncSiblingHashes(type, file, edits, abs) {
  const written = fileHash(abs);
  for (const k of Object.keys(edits))
    if (k.startsWith(type + '/') && edits[k].file === file) edits[k].fileHash = written;
}

function applyGameEdit(type, id, data, applyArt) {
  const found = findGameEntry(type, id);
  if (!found) throw new Error(`no game ${type} with id "${id}" (new content goes through the workspace Install flow)`);
  const err = validateItem(type, data);
  if (err) throw new Error('Validation failed: ' + err);
  const edits = getEdits();
  const key = type + '/' + id;
  const abs = path.join(GAME_ROOT, TYPES[type].dataDir, found.file);
  // First tool edit of this FILE: keep its raw bytes, so restoring the last edit can put the
  // file back byte-for-byte (applies normalize JSON formatting; values alone aren't enough).
  const rawBackup = editBackupFile(type, found.file);
  if (!fs.existsSync(rawBackup)) {
    ensureDir(path.dirname(rawBackup));
    fs.copyFileSync(abs, rawBackup);
  }
  if (!edits[key]) edits[key] = { file: found.file, original: found.data, at: new Date().toISOString() };
  replaceGameEntry(type, id, found.file, data);
  syncSiblingHashes(type, found.file, edits, abs);
  // Optionally replace the game's art with the workspace-generated art for this id.
  const artChanges = [];
  if (applyArt && fs.existsSync(artPath(type, id))) {
    const artDir = artDirFor(type, data);
    if (artDir) {
      const artAbs = path.join(GAME_ROOT, artDir, id + '.png');
      if (!edits[key].art) {
        if (fs.existsSync(artAbs)) {
          ensureDir(path.dirname(editBackupArt(type, id)));
          fs.copyFileSync(artAbs, editBackupArt(type, id));
          edits[key].art = { rel: artDir + '/' + id + '.png', existed: true };
        } else {
          edits[key].art = { rel: artDir + '/' + id + '.png', existed: false };
        }
      }
      ensureDir(path.dirname(artAbs));
      fs.copyFileSync(artPath(type, id), artAbs);
      artChanges.push(edits[key].art.rel);
    }
  }
  setEdits(edits);
  return { file: TYPES[type].dataDir + '/' + found.file, art: artChanges };
}

function restoreGameEdit(type, id) {
  const edits = getEdits();
  const key = type + '/' + id;
  const entry = edits[key];
  if (!entry) throw new Error('no recorded edit for ' + key);
  const abs = path.join(GAME_ROOT, TYPES[type].dataDir, entry.file);
  // Untouched since the tool's last write, and this is the file's last remaining edit?
  // Then restore the ORIGINAL BYTES (exact formatting), not just the entry's values.
  const untouched = entry.fileHash && fs.existsSync(abs) && fileHash(abs) === entry.fileHash;
  const others = Object.keys(edits).some(k =>
    k !== key && k.startsWith(type + '/') && edits[k].file === entry.file);
  const rawBackup = editBackupFile(type, entry.file);
  let usedBackup = false;
  if (untouched && !others && fs.existsSync(rawBackup)) {
    fs.copyFileSync(rawBackup, abs);
    usedBackup = true;
  } else {
    replaceGameEntry(type, id, entry.file, entry.original);
    // Keep every remaining sibling's hash in sync, exactly like applyGameEdit does — otherwise
    // THIS restore's write makes a later sibling restore see a "changed" file and wrongly
    // fall back to value-only again (see syncSiblingHashes).
    if (others) syncSiblingHashes(type, entry.file, edits, abs);
  }
  // Only discard the pristine backup once it was actually consumed. If we fell back to a
  // value-only rewrite (e.g. a genuine external edit was detected), the on-disk file is NOT
  // byte-identical to the backup, so keep it as a manual-recovery safety net rather than
  // silently throwing away the one copy of the untouched original.
  if (usedBackup && fs.existsSync(rawBackup)) fs.unlinkSync(rawBackup);
  if (entry.art) {
    const artAbs = path.join(GAME_ROOT, entry.art.rel);
    if (entry.art.existed && fs.existsSync(editBackupArt(type, id))) {
      fs.copyFileSync(editBackupArt(type, id), artAbs);
      fs.unlinkSync(editBackupArt(type, id));
    } else if (!entry.art.existed) {
      if (fs.existsSync(artAbs)) fs.unlinkSync(artAbs);
      if (fs.existsSync(artAbs + '.import')) fs.unlinkSync(artAbs + '.import');
    }
  }
  delete edits[key];
  setEdits(edits);
  return { file: TYPES[type].dataDir + '/' + entry.file };
}

// ── workspace items ──────────────────────────────────────────────────────────
function itemPath(type, id) { return path.join(WORKSPACE, type, id + '.json'); }
function artPath(type, id) { return path.join(WORKSPACE, 'art', type, id + '.png'); }

function listItems(type) {
  const dir = path.join(WORKSPACE, type);
  if (!fs.existsSync(dir)) return [];
  const manifest = getManifest();
  return fs.readdirSync(dir).filter(f => f.endsWith('.json')).map(f => {
    const id = f.slice(0, -5);
    const data = readJson(path.join(dir, f), null);
    return {
      id,
      data,
      installed: !!manifest[type + '/' + id],
      hasArt: fs.existsSync(artPath(type, id)),
      gameArt: data ? gameArtRel(type, id, data) : null,
    };
  }).filter(x => x.data);
}

// ── install / uninstall ──────────────────────────────────────────────────────
function gameDataFile(type, id) {
  return path.join(TYPES[type].dataDir, `tool_${type}_${id}.json`).replace(/\\/g, '/');
}

// Where this item's art belongs in the game. Enemy-only cards keep their art under
// assets/cards/enemies/ (see CardData.build_from_dict).
function artDirFor(type, data) {
  const t = TYPES[type];
  if (!t.artDir) return null;
  if (type === 'card' && data && data.enemy_only) return 'assets/cards/enemies';
  return t.artDir;
}

// The art the game currently shows for this item, if any — the repo-relative png path, or
// null. Mirrors the game's lookup conventions: enemy cards live under assets/cards/enemies/,
// and abilities fall back to assets/cards/<id>.png (material art predates the migration).
function gameArtRel(type, id, data) {
  const candidates = [];
  const dir = artDirFor(type, data);
  if (dir) candidates.push(dir + '/' + id + '.png');
  if (type === 'ability') candidates.push('assets/cards/' + id + '.png');
  for (const rel of candidates)
    if (fs.existsSync(path.join(GAME_ROOT, rel))) return rel;
  return null;
}

function uninstallItem(type, id) {
  const manifest = getManifest();
  const entry = manifest[type + '/' + id];
  if (!entry) return [];
  const removed = [];
  for (const rel of entry.files) {
    const abs = path.join(GAME_ROOT, rel);
    if (fs.existsSync(abs)) { fs.unlinkSync(abs); removed.push(rel); }
    // Godot may have generated a .import sidecar for deployed art — clean it too.
    if (rel.endsWith('.png') && fs.existsSync(abs + '.import')) {
      fs.unlinkSync(abs + '.import'); removed.push(rel + '.import');
    }
  }
  delete manifest[type + '/' + id];
  setManifest(manifest);
  return removed;
}

function stripMeta(data) {
  if (Array.isArray(data)) return data.map(stripMeta);
  if (data && typeof data === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(data)) {
      if (k.startsWith('_')) continue;
      out[k] = stripMeta(v);
    }
    return out;
  }
  return data;
}

// ── validation (server-side gate before install) ─────────────────────────────
const TRIGGERS = ['on_play','on_death','on_attack','on_damage_taken','permanent','on_turn_start','on_turn_end','on_activate'];
const POLICIES = ['self','single_nearest','single_random','all_enemies','all_allies','all','manual','attack_target','subject','attacker','manual_slot'];
const SUBJECTS = ['self','ally','enemy','any'];
const COMPARATORS = ['gt','gte','lt','lte','eq','neq'];
const MODIFIER_KEYS = ['unit.attack','unit.health','unit.speed','card.cost',
  'mana.initial','mana.max','mana.per_turn','hand.size.initial','draw.per_turn',
  'gold.initial','king.max_health','relic.capacity','reward.essence','reward.king_piece_chance'];
const CUSTOM_HOOKS = ['rallying_cry','deliver_material'];
const EFFECT_ATTRS = ['health','damage_taken','attack','speed','shield','cost'];
const COND_ATTRS = ['health','attack','speed','cost','piece_count','element_count'];
const ELEMENTS = ['fire','water','air','earth','darkness','light'];
const PIECES = ['pawn','knight','bishop','rook','queen','king'];

function validateEffect(e, where) {
  if (!e || typeof e !== 'object') return `${where}: effect must be an object`;
  const kind = e.kind || (e.key ? 'modifier' : e.intercept ? 'interceptor' : e.custom ? 'custom' : 'triggered');
  if (kind === 'modifier') {
    if (!MODIFIER_KEYS.includes(e.key)) return `${where}: unknown modifier key "${e.key}"`;
    if (typeof e.amount !== 'number') return `${where}: modifier needs a numeric amount`;
  } else if (kind === 'interceptor') {
    if (!e.intercept) return `${where}: interceptor needs an "intercept" stat (e.g. damage)`;
    if (e.role && !['source','target'].includes(e.role)) return `${where}: bad role`;
  } else if (kind === 'custom') {
    if (!CUSTOM_HOOKS.includes(e.custom)) return `${where}: unknown custom hook "${e.custom}"`;
    if (e.trigger && !TRIGGERS.includes(e.trigger)) return `${where}: bad trigger "${e.trigger}"`;
    if (e.targeting_policy && !POLICIES.includes(e.targeting_policy)) return `${where}: bad targeting_policy`;
  } else {
    if (e.trigger && !TRIGGERS.includes(e.trigger)) return `${where}: bad trigger "${e.trigger}"`;
    if (e.targeting_policy && !POLICIES.includes(e.targeting_policy)) return `${where}: bad targeting_policy "${e.targeting_policy}"`;
    if (e.subject && !SUBJECTS.includes(e.subject)) return `${where}: bad subject filter`;
    if (e.attribute && !EFFECT_ATTRS.includes(e.attribute)) return `${where}: bad attribute "${e.attribute}"`;
    const hasPayload = e.attribute || (e.status && e.status.id);
    if (!hasPayload) return `${where}: effect does nothing — set an attribute change or a status to apply`;
  }
  for (let i = 0; i < (e.conditions || []).length; i++) {
    const c = e.conditions[i];
    if (c.status) continue;
    if (c.composition) {
      const list = Array.isArray(c.composition) ? c.composition : [c.composition];
      for (const cid of list)
        if (!ELEMENTS.includes(cid) && !PIECES.includes(cid)) return `${where} condition ${i + 1}: "${cid}" is not an element or chess piece`;
      continue;
    }
    if (!COND_ATTRS.includes(c.attribute)) return `${where} condition ${i + 1}: bad attribute "${c.attribute}"`;
    if (!COMPARATORS.includes(c.comparator)) return `${where} condition ${i + 1}: bad comparator`;
  }
  return null;
}

function validateEffects(list, where) {
  for (let i = 0; i < (list || []).length; i++) {
    const err = validateEffect(list[i], `${where} effect ${i + 1}`);
    if (err) return err;
  }
  return null;
}

function validateItem(type, d) {
  if (!validId(d.id)) return 'id must be lowercase letters, digits and underscores';
  switch (type) {
    case 'card': {
      const comp = (d.elements || []).length + (d.chess_pieces || []).length;
      // Stat-less composition cards inherit derived stats in-game (CardData._fill_derived_stats);
      // game files author them without any flag, so infer that form too.
      const derived = !!d._derive_stats || (comp > 0 && d.attack == null);
      if (!derived) {
        for (const f of ['cost','attack','health','speed'])
          if (typeof d[f] !== 'number') return `missing stat "${f}" (or enable derived stats for a composition card)`;
        if (!d.display_name) return 'missing display_name';
      } else if (comp === 0) {
        return 'derived stats need at least one element or chess piece';
      }
      for (const el of d.elements || []) if (!ELEMENTS.includes(el)) return `unknown element "${el}"`;
      for (const p of d.chess_pieces || []) if (!PIECES.includes(p)) return `unknown chess piece "${p}"`;
      return validateEffects(d.effects, 'card');
    }
    case 'relic': {
      if (!d.display_name) return 'missing display_name';
      if (!(d.effects || []).length) return 'a relic needs at least one effect';
      return validateEffects(d.effects, 'relic');
    }
    case 'status': {
      if (d.decay && !['duration','stacks','none','intercept'].includes(d.decay)) return 'bad decay';
      if (d.decay_phase && !['turn_end','turn_start','attack'].includes(d.decay_phase)) return 'bad decay_phase';
      if (d.stacking && !['refresh','extend','stack','independent'].includes(d.stacking)) return 'bad stacking';
      return validateEffects(d.effects, 'status');
    }
    case 'ability': {
      if (!(d.effects || []).length) return 'an ability needs at least one effect';
      if (d.cost && typeof d.cost.mana !== 'number') return 'ability cost needs a mana amount';
      return validateEffects(d.effects, 'ability');
    }
    case 'charm': {
      if (!d.display_name) return 'missing display_name';
      if (d.targets && !['unit','spell','any'].includes(d.targets)) return 'bad targets';
      const hasStats = d.stats && Object.keys(d.stats).length;
      if (!hasStats && !(d.effects || []).length) return 'a charm needs stat bonuses or effects';
      return validateEffects(d.effects, 'charm');
    }
    case 'upgrade': {
      if (!d.display_name) return 'missing display_name';
      if (!(d.nodes || []).length) return 'a tree needs at least one node';
      const ids = new Set();
      for (const n of d.nodes) {
        if (!validId(n.id)) return `node id "${n.id}" must be lowercase letters/digits/underscores`;
        if (ids.has(n.id)) return `duplicate node id "${n.id}"`;
        ids.add(n.id);
      }
      for (const n of d.nodes) {
        for (const r of n.requires || [])
          if (!ids.has(r)) return `node "${n.id}" requires unknown node "${r}"`;
        const err = validateEffects(n.effects, `node "${n.id}"`);
        if (err) return err;
      }
      return null;
    }
    case 'encounter': {
      if (!['combat','elite','boss'].includes(d.node_type)) return 'node_type must be combat, elite or boss';
      if (!(d.enemy_pool || []).length) return 'enemy_pool needs at least one card';
      for (const p of d.enemy_pool) if (!p.id) return 'every enemy_pool entry needs a card id';
      if (!Array.isArray(d.pick_count) || d.pick_count.length !== 2) return 'pick_count must be [min, max]';
      if (d.pick_count[0] > d.pick_count[1]) return 'pick_count min > max';
      return null;
    }
    case 'nodeweights': {
      if (!Array.isArray(d.bands) || !d.bands.length) return 'need at least one floor band';
      for (const b of d.bands) {
        if (typeof b.min_floor !== 'number' || typeof b.max_floor !== 'number') return 'bands need min_floor/max_floor';
        if (!b.weights || !Object.keys(b.weights).length) return 'bands need weights';
      }
      return null;
    }
  }
  return 'unknown type';
}

// nodeweights deploys as the raw band array (the game format), not the {bands} wrapper.
function deployPayload(type, data) {
  if (type === 'nodeweights') return stripMeta(data.bands);
  return stripMeta(data);
}

// ── game vocabulary (scanned live from the game's data folders) ──────────────
function scanGameJson(dirRel) {
  const dir = path.join(GAME_ROOT, dirRel);
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.json')) continue;
    const data = readJson(path.join(dir, f), null);
    if (data == null) continue;
    const entries = Array.isArray(data) ? data : [data];
    for (const e of entries) out.push({ file: f, entry: e });
  }
  return out;
}

function gameVocab() {
  const cards = [];
  for (const { entry: c } of scanGameJson('data/cards')) {
    if (!c.id) continue;
    cards.push({
      id: c.id,
      name: c.display_name || c.id,
      is_king: !!c.is_king,
      enemy_only: !!c.enemy_only,
      card_type: c.card_type || ((c.elements || []).length && !(c.chess_pieces || []).length ? 'spell' : 'unit'),
    });
  }
  const simple = (dirRel) => scanGameJson(dirRel)
    .map(({ entry: e }) => ({ id: e.id, name: e.display_name || e.id }))
    .filter(x => x.id);
  return {
    cards,
    statuses: simple('data/statuses'),
    abilities: simple('data/abilities'),
    charms: simple('data/charms'),
    relics: simple('data/relics'),
    upgrades: simple('data/upgrades'),
    encounters: scanGameJson('data/encounters').map(({ entry: e }) => ({ id: e.id, name: e.id, node_type: e.node_type })).filter(x => x.id),
    elements: ELEMENTS,
    pieces: PIECES,
    triggers: TRIGGERS,
    policies: POLICIES,
    subjects: SUBJECTS,
    comparators: COMPARATORS,
    modifierKeys: MODIFIER_KEYS,
    customHooks: CUSTOM_HOOKS,
    effectAttrs: EFFECT_ATTRS,
    condAttrs: COND_ATTRS,
  };
}

// ── ComfyUI ──────────────────────────────────────────────────────────────────
const jobs = {}; // jobId -> { status, error, type, id, promptId, startedAt }
let jobSeq = 1;

function comfyFetch(urlPath, opts) {
  const base = getSettings().comfyUrl.replace(/\/$/, '');
  return fetch(base + urlPath, opts);
}

function buildFluxWorkflow(prompt, w, h, steps, guidance, seed, prefix, rembg, refName, lora, loraStrength) {
  const save = rembg
    ? { 60: { class_type: 'easy imageRemBg',
              inputs: { images: ['50', 0], rem_mode: 'Inspyrenet', image_output: 'Save',
                        save_prefix: prefix, torchscript_jit: false, add_background: 'none',
                        refine_foreground: true } } }
    : { 60: { class_type: 'SaveImage', inputs: { images: ['50', 0], filename_prefix: prefix } } };
  // Optional image reference: chain LoadImage → FluxKontextImageScale → VAEEncode →
  // ReferenceLatent onto the text conditioning (Flux 2 reuses the Kontext reference path,
  // same graph tools/comfy_ref_gen.py builds).
  const ref = refName ? {
    70: { class_type: 'LoadImage', inputs: { image: refName } },
    71: { class_type: 'FluxKontextImageScale', inputs: { image: ['70', 0] } },
    72: { class_type: 'VAEEncode', inputs: { pixels: ['71', 0], vae: ['12', 0] } },
    73: { class_type: 'ReferenceLatent', inputs: { conditioning: ['20', 0], latent: ['72', 0] } },
  } : {};
  const conditioning = refName ? ['73', 0] : ['20', 0];
  // Optional speed LoRA (e.g. Flux 2 Turbo) folded into the UNET before guiding.
  const loraNodes = lora ? {
    15: { class_type: 'LoraLoaderModelOnly',
          inputs: { lora_name: lora, strength_model: loraStrength == null ? 1.0 : loraStrength, model: ['10', 0] } },
  } : {};
  const model = lora ? ['15', 0] : ['10', 0];
  return Object.assign(save, ref, loraNodes, {
    10: { class_type: 'UNETLoader', inputs: { unet_name: 'flux2_dev_fp8mixed.safetensors', weight_dtype: 'default' } },
    11: { class_type: 'CLIPLoader', inputs: { clip_name: 'mistral_3_small_flux2_bf16.safetensors', type: 'flux2' } },
    12: { class_type: 'VAELoader', inputs: { vae_name: 'flux2-vae.safetensors' } },
    20: { class_type: 'CLIPTextEncode', inputs: { text: prompt, clip: ['11', 0] } },
    21: { class_type: 'FluxGuidance', inputs: { conditioning, guidance } },
    30: { class_type: 'BasicGuider', inputs: { model, conditioning: ['21', 0] } },
    31: { class_type: 'KSamplerSelect', inputs: { sampler_name: 'euler' } },
    32: { class_type: 'Flux2Scheduler', inputs: { steps, width: w, height: h } },
    33: { class_type: 'RandomNoise', inputs: { noise_seed: seed } },
    34: { class_type: 'EmptyFlux2LatentImage', inputs: { width: w, height: h, batch_size: 1 } },
    40: { class_type: 'SamplerCustomAdvanced',
          inputs: { noise: ['33', 0], guider: ['30', 0], sampler: ['31', 0], sigmas: ['32', 0], latent_image: ['34', 0] } },
    50: { class_type: 'VAEDecode', inputs: { samples: ['40', 0], vae: ['12', 0] } },
  });
}

// The image "current art" refers to for an item: the game's installed art when it exists
// (the stable original — what "restyle this card" means), else the workspace-generated art.
function currentArtAbs(type, id) {
  const wsItem = readJson(itemPath(type, id), null);
  const gameEntry = wsItem ? null : findGameEntry(type, id);
  const data = wsItem || (gameEntry && gameEntry.data) || {};
  const rel = gameArtRel(type, id, data);
  if (rel) return path.join(GAME_ROOT, rel);
  if (fs.existsSync(artPath(type, id))) return artPath(type, id);
  return null;
}

// Push a local image into ComfyUI's input folder (POST /upload/image, multipart).
async function uploadRefImage(absPath, name) {
  const form = new FormData();
  form.append('image', new Blob([fs.readFileSync(absPath)], { type: 'image/png' }), name);
  form.append('overwrite', 'true');
  const res = await comfyFetch('/upload/image', { method: 'POST', body: form });
  if (!res.ok) throw new Error(`ComfyUI image upload failed: HTTP ${res.status} ${await res.text()}`);
  const out = await res.json();
  return out.name || name;
}

async function startArtJob({ type, id, prompt, width, height, steps, guidance, seed, rembg, useRef, turbo }) {
  const t = TYPES[type];
  if (!t) throw new Error('unknown type');
  if (!validId(id)) throw new Error('bad item id');
  const w = width || t.artW, h = height || t.artH;
  const s = (seed == null || seed < 0) ? Math.floor(Math.random() * 2 ** 32) : seed;
  const doRembg = rembg == null ? t.rembg : !!rembg;
  const prefix = `tool_${type}_${id}`;
  let refName = null;
  if (useRef) {
    const refAbs = currentArtAbs(type, id);
    if (!refAbs) throw new Error('this item has no current art to use as input');
    refName = await uploadRefImage(refAbs, `tool_ref_${type}_${id}.png`);
  }
  const settings = getSettings();
  let lora = null, loraStrength = 1.0;
  if (turbo) {
    if (!settings.turboLora) throw new Error('no turbo LoRA configured — set one in Settings');
    lora = settings.turboLora;
    loraStrength = settings.turboStrength == null ? 1.0 : settings.turboStrength;
  }
  const wf = buildFluxWorkflow(prompt, w, h, steps || (turbo ? settings.turboSteps || 8 : 20),
    guidance || 4.0, s, prefix, doRembg, refName, lora, loraStrength);
  const res = await comfyFetch('/prompt', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: wf }),
  });
  if (!res.ok) throw new Error(`ComfyUI queue failed: HTTP ${res.status} ${await res.text()}`);
  const { prompt_id } = await res.json();
  const jobId = String(jobSeq++);
  jobs[jobId] = { status: 'running', type, id, promptId: prompt_id, seed: s, startedAt: Date.now(), error: null };
  pollJob(jobId);
  return { jobId, seed: s };
}

async function pollJob(jobId) {
  const job = jobs[jobId];
  for (;;) {
    if (Date.now() - job.startedAt > 15 * 60 * 1000) {
      job.status = 'error'; job.error = 'timed out after 15 minutes'; return;
    }
    await new Promise(r => setTimeout(r, 2000));
    let hist;
    try {
      const res = await comfyFetch('/history/' + job.promptId);
      hist = await res.json();
    } catch (e) { continue; }
    const h = hist[job.promptId];
    if (!h) continue;
    const statusStr = (h.status && h.status.status_str) || '?';
    if (statusStr === 'error') {
      const msgs = JSON.stringify((h.status && h.status.messages) || []).slice(0, 2000);
      job.status = 'error'; job.error = 'ComfyUI error: ' + msgs; return;
    }
    // grab the first output image
    for (const node of Object.values(h.outputs || {})) {
      for (const img of node.images || []) {
        try {
          const qs = new URLSearchParams({ filename: img.filename, subfolder: img.subfolder || '', type: img.type || 'output' });
          const res = await comfyFetch('/view?' + qs.toString());
          if (!res.ok) throw new Error('view HTTP ' + res.status);
          const buf = Buffer.from(await res.arrayBuffer());
          const dest = artPath(job.type, job.id);
          ensureDir(path.dirname(dest));
          fs.writeFileSync(dest, buf);
          job.status = 'done';
          return;
        } catch (e) {
          job.status = 'error'; job.error = 'fetching image failed: ' + e.message; return;
        }
      }
    }
    job.status = 'error'; job.error = 'ComfyUI finished but produced no image (status ' + statusStr + ')';
    return;
  }
}

// ── HTTP plumbing ────────────────────────────────────────────────────────────
function send(res, code, data, ctype) {
  const body = ctype ? data : JSON.stringify(data);
  res.writeHead(code, { 'Content-Type': ctype || 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let buf = '';
    req.on('data', c => { buf += c; if (buf.length > 20e6) reject(new Error('body too large')); });
    req.on('end', () => { try { resolve(buf ? JSON.parse(buf) : {}); } catch (e) { reject(e); } });
  });
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.json': 'application/json' };

async function handle(req, res) {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  try {
    // ---- API ----
    if (p === '/api/state') {
      const items = {};
      const game = {};
      const edits = getEdits();
      for (const t of Object.keys(TYPES)) {
        items[t] = listItems(t);
        game[t] = listGameEntries(t).map(e => ({
          id: e.id,
          name: (e.data && e.data.display_name) || e.id,
          file: e.file,
          edited: !!edits[t + '/' + e.id],
          art: gameArtRel(t, e.id, e.data),
        }));
      }
      return send(res, 200, {
        gameRoot: GAME_ROOT,
        types: Object.fromEntries(Object.entries(TYPES).map(([k, v]) => [k, {
          label: v.label, dataDir: v.dataDir, artDir: v.artDir, artW: v.artW, artH: v.artH, rembg: v.rembg,
        }])),
        items,
        game,
        vocab: gameVocab(),
        settings: getSettings(),
      });
    }
    if (p === '/api/game/item') {
      const type = url.searchParams.get('type'), id = url.searchParams.get('id');
      if (!TYPES[type]) return send(res, 400, { error: 'unknown type' });
      const found = findGameEntry(type, id);
      if (!found) return send(res, 404, { error: 'not found' });
      const edits = getEdits();
      return send(res, 200, { id: found.id, file: found.file, data: found.data,
        edited: !!edits[type + '/' + id], hasArt: fs.existsSync(artPath(type, id)),
        gameArt: gameArtRel(type, id, found.data) });
    }
    if (p === '/api/game/apply' && req.method === 'POST') {
      const { type, id, data, applyArt } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      if (!data || data.id !== id) return send(res, 400, { error: 'the id of existing game content cannot change' });
      try {
        return send(res, 200, Object.assign({ ok: true }, applyGameEdit(type, id, data, !!applyArt)));
      } catch (e) { return send(res, 400, { error: e.message }); }
    }
    if (p === '/api/game/restore' && req.method === 'POST') {
      const { type, id } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      try {
        return send(res, 200, Object.assign({ ok: true }, restoreGameEdit(type, id)));
      } catch (e) { return send(res, 400, { error: e.message }); }
    }
    if (p === '/api/item/save' && req.method === 'POST') {
      const { type, data } = await readBody(req);
      if (!TYPES[type]) return send(res, 400, { error: 'unknown type' });
      if (!validId(data && data.id)) return send(res, 400, { error: 'id must be lowercase letters, digits and underscores' });
      writeJson(itemPath(type, data.id), data);
      // an installed item that changes needs a re-install to reach the game — report that
      const installed = !!getManifest()[type + '/' + data.id];
      return send(res, 200, { ok: true, installed });
    }
    if (p === '/api/item/delete' && req.method === 'POST') {
      const { type, id } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      uninstallItem(type, id);
      if (fs.existsSync(itemPath(type, id))) fs.unlinkSync(itemPath(type, id));
      if (fs.existsSync(artPath(type, id))) fs.unlinkSync(artPath(type, id));
      return send(res, 200, { ok: true });
    }
    if (p === '/api/item/install' && req.method === 'POST') {
      const { type, id } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      const data = readJson(itemPath(type, id), null);
      if (!data) return send(res, 404, { error: 'item not found' });
      const err = validateItem(type, data);
      if (err) return send(res, 400, { error: err });
      // write the deploy payload form (nodeweights unwraps to the raw band array)
      const files = [];
      const rel = gameDataFile(type, id);
      const abs = path.join(GAME_ROOT, rel);
      ensureDir(path.dirname(abs));
      fs.writeFileSync(abs, JSON.stringify(deployPayload(type, data), null, 2) + '\n', 'utf8');
      files.push(rel);
      const artDir = artDirFor(type, data);
      if (artDir && fs.existsSync(artPath(type, id))) {
        const artRel = artDir + '/' + id + '.png';
        const artAbs = path.join(GAME_ROOT, artRel);
        const manifest0 = getManifest();
        const ours = Object.values(manifest0).some(e => e.files.includes(artRel));
        if (fs.existsSync(artAbs) && !ours) {
          // roll back the JSON write so a failed install leaves nothing behind
          fs.unlinkSync(abs);
          return send(res, 409, { error: `Game already has art at ${artRel} that this tool didn't create. Rename the item id or remove that file manually.` });
        }
        ensureDir(path.dirname(artAbs));
        fs.copyFileSync(artPath(type, id), artAbs);
        files.push(artRel);
      }
      const manifest = getManifest();
      manifest[type + '/' + id] = { files, at: new Date().toISOString() };
      setManifest(manifest);
      return send(res, 200, { ok: true, files });
    }
    if (p === '/api/item/uninstall' && req.method === 'POST') {
      const { type, id } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      const removed = uninstallItem(type, id);
      return send(res, 200, { ok: true, removed });
    }
    if (p === '/api/validate' && req.method === 'POST') {
      const { type, data } = await readBody(req);
      if (!TYPES[type]) return send(res, 400, { error: 'unknown type' });
      const err = validateItem(type, data || {});
      return send(res, 200, { ok: !err, error: err });
    }
    if (p === '/api/settings' && req.method === 'POST') {
      const body = await readBody(req);
      const s = getSettings();
      if (body.comfyUrl) s.comfyUrl = String(body.comfyUrl);
      // shared art style: one live prompt fragment + named presets, global across items
      if ('artStyle' in body) s.artStyle = String(body.artStyle || '');
      if (body.stylePresets && typeof body.stylePresets === 'object') {
        s.stylePresets = {};
        for (const [k, v] of Object.entries(body.stylePresets)) s.stylePresets[k] = String(v);
      }
      if ('turboLora' in body) s.turboLora = String(body.turboLora || '');
      if ('turboSteps' in body) s.turboSteps = Math.max(1, parseInt(body.turboSteps, 10) || 8);
      if ('turboStrength' in body) s.turboStrength = parseFloat(body.turboStrength) || 1.0;
      writeJson(SETTINGS_PATH, s);
      return send(res, 200, { ok: true, settings: s });
    }
    if (p === '/api/comfy/loras') {
      try {
        const r = await comfyFetch('/models/loras');
        return send(res, 200, { ok: true, loras: await r.json() });
      } catch (e) {
        return send(res, 200, { ok: false, loras: [], error: e.message });
      }
    }
    if (p === '/api/comfy/health') {
      try {
        const r = await comfyFetch('/system_stats');
        const stats = await r.json();
        return send(res, 200, { ok: true, version: stats.system && stats.system.comfyui_version });
      } catch (e) {
        return send(res, 200, { ok: false, error: e.message });
      }
    }
    if (p === '/api/art/generate' && req.method === 'POST') {
      const body = await readBody(req);
      if (!body.prompt || !String(body.prompt).trim()) return send(res, 400, { error: 'prompt is required' });
      try {
        const out = await startArtJob(body);
        return send(res, 200, out);
      } catch (e) {
        return send(res, 502, { error: e.message });
      }
    }
    if (p === '/api/art/job') {
      const job = jobs[url.searchParams.get('id')];
      if (!job) return send(res, 404, { error: 'no such job' });
      return send(res, 200, { status: job.status, error: job.error, type: job.type, id: job.id, seed: job.seed,
        elapsed: Math.round((Date.now() - job.startedAt) / 1000) });
    }
    if (p === '/api/art/delete' && req.method === 'POST') {
      const { type, id } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      if (fs.existsSync(artPath(type, id))) fs.unlinkSync(artPath(type, id));
      return send(res, 200, { ok: true });
    }
    // workspace art preview
    if (p.startsWith('/art/')) {
      const m = p.match(/^\/art\/([a-z]+)\/([a-z0-9_]+)\.png$/);
      if (m && TYPES[m[1]] && fs.existsSync(artPath(m[1], m[2]))) {
        return send(res, 200, fs.readFileSync(artPath(m[1], m[2])), 'image/png');
      }
      return send(res, 404, { error: 'no art' });
    }
    // existing game art preview (read-only, for reference while authoring)
    if (p.startsWith('/gameart/')) {
      const rel = decodeURIComponent(p.slice('/gameart/'.length));
      if (rel.includes('..') || !rel.startsWith('assets/') || !rel.endsWith('.png')) return send(res, 400, { error: 'bad path' });
      const abs = path.join(GAME_ROOT, rel);
      if (!fs.existsSync(abs)) return send(res, 404, { error: 'not found' });
      return send(res, 200, fs.readFileSync(abs), 'image/png');
    }
    // ---- static ----
    let file = p === '/' ? '/index.html' : p;
    const abs = path.normalize(path.join(PUBLIC, file));
    if (!abs.startsWith(PUBLIC)) return send(res, 403, { error: 'forbidden' });
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) {
      return send(res, 200, fs.readFileSync(abs), MIME[path.extname(abs)] || 'application/octet-stream');
    }
    return send(res, 404, { error: 'not found' });
  } catch (e) {
    return send(res, 500, { error: e.message });
  }
}

if (require.main === module) {
  http.createServer(handle).listen(PORT, '127.0.0.1', () => {
    console.log(`CardGame Authoring Tool  →  http://127.0.0.1:${PORT}`);
    console.log(`Game root: ${GAME_ROOT}`);
  });
}

module.exports = { validateItem, buildFluxWorkflow, TYPES, gameVocab };
