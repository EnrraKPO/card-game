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
  // status pips DO have an art slot: StatusData.icon() loads assets/ui/status/<id>_status.png
  // (optional — pips fall back to glyph+colour), hence the artSuffix on the deployed filename
  status:     { label: 'Status',          dataDir: 'data/statuses',   artDir: 'assets/ui/status', artSuffix: '_status', artW: 512, artH: 512, rembg: true },
  // ability art is formatted like card art (user directive): portrait canvas, no rembg
  ability:    { label: 'Ability',         dataDir: 'data/abilities',  artDir: 'assets/abilities', artW: 1024, artH: 1536, rembg: false },
  charm:      { label: 'Charm',           dataDir: 'data/charms',     artDir: null,               artW: 512,  artH: 512,  rembg: true  },
  // upgrade trees carry an EMBLEM shown on the Upgrades screen's detail strip
  upgrade:    { label: 'Upgrade Tree',    dataDir: 'data/upgrades',   artDir: 'assets/ui/upgrades', artW: 512, artH: 512, rembg: true },
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
ensureDir(path.join(WORKSPACE, 'refs'));   // user-uploaded external reference images

// Uploaded reference filenames pass through URLs and the ComfyUI input folder — keep them tame.
function safeRefName(name) { return String(name || 'reference.png').replace(/[^a-zA-Z0-9._-]/g, '_'); }

// ── settings ─────────────────────────────────────────────────────────────────
const SETTINGS_PATH = path.join(WORKSPACE, 'settings.json');
function getSettings() {
  return Object.assign({
    comfyUrl: 'http://127.0.0.1:8187', artStyle: '', stylePresets: {},
    conceptPresets: {}, refHintPresets: {},   // named presets for the ✨ LLM guidance inputs
    flowPresets: {},   // named multi-step generation flows (JSON-encoded step arrays)
    kinAdherence: 'concept',   // ✨ inference default: what carries over from the anchor
    kinAnchorMode: 'current',  // 'current' = own art first, else base unit | 'base' = always the base unit
    kinThemeMode: 'family',    // 'family' = auto element-relatives | 'select' = the hand-picked kinThemeRefs
    kinThemeRefs: [],          // card ids picked as theme references (used when kinThemeMode='select')
    useArtGuides: false,       // opt-in: inject the composition-keyed art_guides into every ✨ writer
    kinSteer: '',              // always-on free-text creative direction; empty = contributes nothing
    turboLora: 'Flux_2-Turbo-LoRA_comfyui.safetensors',  // the user's Flux 2 turbo LoRA
    turboSteps: 8, turboStrength: 1.0,
    llmProvider: 'ollama',   // 'ollama' (local) | 'claude-code' (subscription) | 'claude' (API) | 'openai' — routes ALL ✨ LLM features
    claudeCodeModel: '',     // blank = the user's Claude Code default; or opus/sonnet/haiku/full id
    claudeCliCmd: 'claude',  // launcher override (tests point it at a stub)
    ollamaUrl: 'http://127.0.0.1:11434', llmModel: 'gemma4:31b',   // local LLM for art prompts
    effectsModel: 'qwen3-coder-next:q4_K_M',   // local LLM for ✨ effects-from-words (JSON work — a coder model)
    claudeModel: 'claude-opus-4-8',   // cloud providers use ONE model for every ✨ feature
    openaiModel: 'gpt-5.5',
  }, readJson(SETTINGS_PATH, {}));
}

// ── art guides ───────────────────────────────────────────────────────────────
// Tool-bound authored art direction, keyed by COMPOSITION (not by card): `concept` by
// sorted piece-multiset ("bishop_bishop" → Hierophant), `theme` by sorted element-multiset
// ("air_fire" → Lightning). Each entry = {label, positive, negative}. The positive is
// authoritative direction the family art can't convey; the negative is the anti-drift
// guard. Exact-multiset match, self-contained — no guide → the writer infers as before.
// Injected into every ✨ writer only when settings.useArtGuides is on.
const GUIDES_PATH = path.join(WORKSPACE, 'art_guides.json');
function getArtGuides() {
  const g = readJson(GUIDES_PATH, {});
  return { concept: (g && g.concept) || {}, theme: (g && g.theme) || {} };
}
function compKey(arr) { return (Array.isArray(arr) ? arr.slice() : []).sort().join('_'); }

// The authored guide lines for a card's composition, or [] when guides are off / none match.
function artGuideLines(elements, pieces) {
  if (!getSettings().useArtGuides) return [];
  const g = getArtGuides();
  const c = g.concept[compKey(pieces)];
  const t = g.theme[compKey(elements)];
  const lines = [], neg = [];
  if (c && c.positive) lines.push(`Concept direction (AUTHORITATIVE — the subject is this): ${c.positive}`);
  if (t && t.positive) lines.push(`Theme direction (AUTHORITATIVE — the look/palette is this): ${t.positive}`);
  if (c && c.negative) neg.push(c.negative);
  if (t && t.negative) neg.push(t.negative);
  if (neg.length) lines.push(`Avoid — do NOT depict: ${neg.join('; ')}`);
  return lines;
}

// The always-on free-text steering nudge (global, all flows). Empty → no line.
function steerLines() {
  const s = (getSettings().kinSteer || '').trim();
  return s ? [`Creative direction (follow this): ${s}`] : [];
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
// `includeTool` also lists entries from tool-deployed files (data/…/tool_<type>_<id>.json),
// tagged with their owning workspace item — so installed content is BROWSABLE among the
// game's cards while remaining workspace-managed (in-place editing still refuses them:
// findGameEntry keeps the default excludeTool view).
function listGameEntries(type, includeTool = false) {
  const dir = path.join(GAME_ROOT, TYPES[type].dataDir);
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.json')) continue;
    const toolMatch = f.match(/^tool_([a-z]+)_([a-z0-9_]+)\.json$/);
    if (toolMatch && !includeTool) continue;
    const owner = toolMatch ? { type: toolMatch[1], id: toolMatch[2] } : null;
    const raw = readJson(path.join(dir, f), null);
    if (raw == null) continue;
    if (type === 'nodeweights') {
      if (Array.isArray(raw)) out.push({ id: f.slice(0, -5), file: f, data: { id: f.slice(0, -5), bands: raw }, tool: owner });
      continue;
    }
    const entries = Array.isArray(raw) ? raw : [raw];
    for (const e of entries) if (e && e.id) out.push({ id: e.id, file: f, data: e, tool: owner });
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

// ── entry-centric authoring on REAL game files (the final model) ─────────────────────
// Save an entry INTO a game data file: replace it where it already lives, append it to the
// chosen file otherwise (creating the file if needed). Every change is snapshotted in the
// edits manifest so Revert works: replaced entries restore their original, added entries
// get REMOVED again. "Uninstalling" content is not a verb — it's the `enabled: false`
// property, which the game's loaders now respect.
function saveGameEntry(type, file, data) {
  if (!/^[a-z0-9_]+\.json$/.test(file)) throw new Error('file must be a plain lowercase name ending in .json');
  const err = validateItem(type, data);
  if (err) throw new Error('Validation failed: ' + err);
  const existing = findGameEntry(type, data.id);
  const edits = getEdits();
  const key = type + '/' + data.id;
  if (existing) {
    // replace in the file it already lives in (the chosen file is ignored for existing ids —
    // an entry has ONE home; moving between files is a delete + re-add)
    const abs = path.join(GAME_ROOT, TYPES[type].dataDir, existing.file);
    const rawBackup = editBackupFile(type, existing.file);
    if (!fs.existsSync(rawBackup)) { ensureDir(path.dirname(rawBackup)); fs.copyFileSync(abs, rawBackup); }
    if (!edits[key]) edits[key] = { file: existing.file, original: existing.data, at: new Date().toISOString() };
    replaceGameEntry(type, data.id, existing.file, data);
    syncSiblingHashes(type, existing.file, edits, abs);
    setEdits(edits);
    return { file: TYPES[type].dataDir + '/' + existing.file, action: 'updated' };
  }
  const abs = path.join(GAME_ROOT, TYPES[type].dataDir, file);
  let raw = [];
  if (fs.existsSync(abs)) {
    const rawBackup = editBackupFile(type, file);
    if (!fs.existsSync(rawBackup)) { ensureDir(path.dirname(rawBackup)); fs.copyFileSync(abs, rawBackup); }
    raw = readJson(abs, null);
    if (raw == null) throw new Error(`cannot parse ${file}`);
    if (!Array.isArray(raw)) raw = [raw];   // single-object files grow into arrays
  } else {
    ensureDir(path.dirname(abs));
  }
  raw.push(stripMeta(data));
  writeGameJson(abs, raw);
  if (!edits[key]) edits[key] = { file, original: null, added: true, at: new Date().toISOString() };
  syncSiblingHashes(type, file, edits, abs);
  setEdits(edits);
  // pending workspace art (generated before the entry was saved) deploys now
  const art = deployArtIfPossible(type, data.id);
  return { file: TYPES[type].dataDir + '/' + file, action: 'added', art };
}

// Remove an entry from its file (snapshot kept: Revert re-adds it). An emptied file is
// deleted outright.
function deleteGameEntry(type, id) {
  const existing = findGameEntry(type, id);
  if (!existing) throw new Error(`no game ${type} with id "${id}"`);
  const abs = path.join(GAME_ROOT, TYPES[type].dataDir, existing.file);
  const rawBackup = editBackupFile(type, existing.file);
  if (!fs.existsSync(rawBackup)) { ensureDir(path.dirname(rawBackup)); fs.copyFileSync(abs, rawBackup); }
  const edits = getEdits();
  const key = type + '/' + id;
  let raw = readJson(abs, null);
  if (!Array.isArray(raw)) raw = [raw];
  const remaining = raw.filter(e => !(e && e.id === id));
  if (remaining.length) { writeGameJson(abs, remaining); syncSiblingHashes(type, existing.file, edits, abs); }
  else fs.unlinkSync(abs);
  edits[key] = { file: existing.file, original: existing.data, deleted: true, at: new Date().toISOString() };
  setEdits(edits);
  return { file: TYPES[type].dataDir + '/' + existing.file, removedFile: !remaining.length };
}

// Relocate an entry to another file of its type — the set generator's "pull an existing
// composition into the family file". ONE bookkeeping record covers both files (`movedFrom`),
// so Revert removes it from the target and puts the original back in its source. Composing
// this from delete + save would break revert: both share the edits key `type/id`, and the
// second write would shadow the first record.
function moveGameEntry(type, id, file) {
  if (!/^[a-z0-9_]+\.json$/.test(file)) throw new Error('file must be a plain lowercase name ending in .json');
  if (type === 'nodeweights') throw new Error('node-weight bands cannot move between files');
  const existing = findGameEntry(type, id);
  if (!existing) throw new Error(`no game ${type} with id "${id}"`);
  if (existing.file === file) return { file: TYPES[type].dataDir + '/' + file, action: 'in_place' };
  const srcAbs = path.join(GAME_ROOT, TYPES[type].dataDir, existing.file);
  const dstAbs = path.join(GAME_ROOT, TYPES[type].dataDir, file);
  // raw-byte backups for BOTH files on their first tool touch, same as save/delete
  for (const [f, abs] of [[existing.file, srcAbs], [file, dstAbs]]) {
    if (!fs.existsSync(abs)) continue;
    const b = editBackupFile(type, f);
    if (!fs.existsSync(b)) { ensureDir(path.dirname(b)); fs.copyFileSync(abs, b); }
  }
  const edits = getEdits();
  const key = type + '/' + id;
  // out of the source (an emptied file disappears, like delete-entry)
  let src = readJson(srcAbs, null);
  if (src == null) throw new Error(`cannot parse ${existing.file}`);
  if (!Array.isArray(src)) src = [src];
  const remaining = src.filter(e => !(e && e.id === id));
  if (remaining.length) { writeGameJson(srcAbs, remaining); syncSiblingHashes(type, existing.file, edits, srcAbs); }
  else fs.unlinkSync(srcAbs);
  // into the target, definition verbatim (created if needed; single-object files grow)
  let dst = fs.existsSync(dstAbs) ? readJson(dstAbs, null) : [];
  if (dst == null) throw new Error(`cannot parse ${file}`);
  if (!Array.isArray(dst)) dst = [dst];
  dst.push(stripMeta(existing.data));
  ensureDir(path.dirname(dstAbs));
  writeGameJson(dstAbs, dst);
  // bookkeeping: a fresh record remembers the source; a prior record keeps ITS original
  // (revert then undoes the earlier edit AND the move in one step). A prior `added`
  // record stays `added` — reverting a tool-created entry still just removes it.
  if (!edits[key]) edits[key] = { file, original: existing.data, movedFrom: existing.file, at: new Date().toISOString() };
  else { edits[key].movedFrom = edits[key].movedFrom || edits[key].file; edits[key].file = file; }
  syncSiblingHashes(type, file, edits, dstAbs);
  setEdits(edits);
  return { file: TYPES[type].dataDir + '/' + file, action: 'moved', from: existing.file };
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
      const artAbs = path.join(GAME_ROOT, artDir, artFileFor(type, id));
      if (!edits[key].art) {
        if (fs.existsSync(artAbs)) {
          ensureDir(path.dirname(editBackupArt(type, id)));
          fs.copyFileSync(artAbs, editBackupArt(type, id));
          edits[key].art = { rel: artDir + '/' + artFileFor(type, id), existed: true };
        } else {
          edits[key].art = { rel: artDir + '/' + artFileFor(type, id), existed: false };
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
  // A cross-file move can't take this shortcut: the target's backup predates the move,
  // so restoring it fixes ONE file while the source also needs its entry back.
  const untouched = entry.fileHash && fs.existsSync(abs) && fileHash(abs) === entry.fileHash;
  const others = Object.keys(edits).some(k =>
    k !== key && k.startsWith(type + '/') && edits[k].file === entry.file);
  const crossFileMove = !!entry.movedFrom && !entry.added;
  const rawBackup = editBackupFile(type, entry.file);
  let usedBackup = false;
  if (untouched && !others && !crossFileMove && fs.existsSync(rawBackup)) {
    fs.copyFileSync(rawBackup, abs);
    usedBackup = true;
  } else if (entry.added) {
    // reverting an ADDED entry = remove it again
    let raw = readJson(abs, null);
    if (raw != null) {
      if (!Array.isArray(raw)) raw = [raw];
      const remaining = raw.filter(e => !(e && e.id === id));
      if (remaining.length) { writeGameJson(abs, remaining); if (others) syncSiblingHashes(type, entry.file, edits, abs); }
      else fs.unlinkSync(abs);
    }
  } else if (entry.movedFrom) {
    // reverting a MOVE = out of the target, original back into the source
    let dst = fs.existsSync(abs) ? readJson(abs, null) : null;
    if (dst != null) {
      if (!Array.isArray(dst)) dst = [dst];
      const remaining = dst.filter(e => !(e && e.id === id));
      if (remaining.length) { writeGameJson(abs, remaining); if (others) syncSiblingHashes(type, entry.file, edits, abs); }
      else fs.unlinkSync(abs);
    }
    const srcAbs = path.join(GAME_ROOT, TYPES[type].dataDir, entry.movedFrom);
    let src = fs.existsSync(srcAbs) ? readJson(srcAbs, null) : [];
    if (src == null) src = [];
    if (!Array.isArray(src)) src = [src];
    src.push(entry.original);
    ensureDir(path.dirname(srcAbs));
    writeGameJson(srcAbs, src);
    syncSiblingHashes(type, entry.movedFrom, edits, srcAbs);
  } else if (entry.deleted) {
    // reverting a DELETED entry = put it back
    let raw = fs.existsSync(abs) ? readJson(abs, null) : [];
    if (raw == null) raw = [];
    if (!Array.isArray(raw)) raw = [raw];
    raw.push(entry.original);
    writeGameJson(abs, raw);
    if (others) syncSiblingHashes(type, entry.file, edits, abs);
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

// The game-side art FILENAME for this item — statuses deploy as <id>_status.png
// (StatusData's lookup convention); every other type is plain <id>.png.
function artFileFor(type, id) { return id + (TYPES[type].artSuffix || '') + '.png'; }

// The art the game currently shows for this item, if any — the repo-relative png path, or
// null. Mirrors the game's lookup conventions: enemy cards live under assets/cards/enemies/,
// and abilities fall back to assets/cards/<id>.png (material art predates the migration).
function gameArtRel(type, id, data) {
  const candidates = [];
  const dir = artDirFor(type, data);
  if (dir) candidates.push(dir + '/' + artFileFor(type, id));
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
// The native trigger-resolver schema (see scripts/triggers/trigger_resolver.gd).
const SIMPLE_EVENTS = ['play','death','activate','turn_start','turn_end'];
const DUAL_EVENTS = ['attack','struck'];
const RELATIONS = ['self','ally','enemy'];   // legacy spelling; ally/enemy map to allegiance in-game
const ALLEGIANCES = ['ally','enemy'];        // side vs the effect's OWNER — the native predicate form
const PARTICIPANT_GATES = ['self','any'];    // trigger "of" gates (identity is structural, not a condition)
const TRACKER_KINDS = ['container','stacks'];
// The native targeting schema (see scripts/triggers/target_resolver.gd).
const TARGET_KINDS = ['self','all','auto','manual','manual_slot','participant'];
const CRITERIA = ['nearest','random'];
const PARTICIPANTS = ['holder','origin','destination'];
const POLICIES = ['self','single_nearest','single_random','all_enemies','all_allies','all','manual','attack_target','subject','attacker','manual_slot'];
const SUBJECTS = ['self','ally','enemy','any'];
const COMPARATORS = ['gt','gte','lt','lte','eq','neq'];
const MODIFIER_KEYS = ['unit.attack','unit.health','unit.speed','card.cost',
  'mana.initial','mana.max','mana.per_turn','hand.size.initial','draw.per_turn',
  'gold.initial','king.max_health','relic.capacity','reward.essence','reward.king_piece_chance'];
const CUSTOM_HOOKS = ['rallying_cry','deliver_material'];
const EFFECT_ATTRS = ['health','max_health','damage_taken','attack','speed','shield','cost'];
const COND_ATTRS = ['health','attack','speed','cost','piece_count','element_count'];
const ELEMENTS = ['fire','water','air','earth','darkness','light'];
const PIECES = ['pawn','knight','bishop','rook','queen','king'];

function validateConditionList(list, where) {
  for (let i = 0; i < (list || []).length; i++) {
    const c = list[i];
    if (c.status) continue;
    if (c.allegiance) {
      if (!ALLEGIANCES.includes(c.allegiance)) return `${where} condition ${i + 1}: bad allegiance "${c.allegiance}"`;
      continue;
    }
    if (c.relation) {
      if (!RELATIONS.includes(c.relation)) return `${where} condition ${i + 1}: bad relation "${c.relation}"`;
      continue;
    }
    if (c.card_type) {
      if (!['unit','spell'].includes(c.card_type)) return `${where} condition ${i + 1}: bad card_type "${c.card_type}"`;
      continue;
    }
    if (c.has_element !== undefined) {
      if (typeof c.has_element !== 'boolean') return `${where} condition ${i + 1}: has_element must be a boolean`;
      continue;
    }
    if (c.composition) {
      const compList = Array.isArray(c.composition) ? c.composition : [c.composition];
      for (const cid of compList)
        if (!ELEMENTS.includes(cid) && !PIECES.includes(cid)) return `${where} condition ${i + 1}: "${cid}" is not an element or chess piece`;
      continue;
    }
    if (!COND_ATTRS.includes(c.attribute)) return `${where} condition ${i + 1}: bad attribute "${c.attribute}"`;
    if (!COMPARATORS.includes(c.comparator)) return `${where} condition ${i + 1}: bad comparator`;
  }
  return null;
}

// The trigger may be a legacy string or a native resolver object.
function validateTrigger(t, where) {
  if (t == null) return null;                       // omitted = legacy default on_play
  if (typeof t === 'string') {
    if (!TRIGGERS.includes(t)) return `${where}: bad trigger "${t}"`;
    return null;
  }
  if (typeof t !== 'object') return `${where}: trigger must be a string or an object`;
  const kind = String(t.kind || 'event');
  if (kind === 'transient') return null;
  if (kind === 'while') return null;   // standing: no event, no participants — lifetime is the tracker's
  if (kind === 'event') {
    if (!SIMPLE_EVENTS.includes(String(t.event))) return `${where}: "${t.event}" is not a simple event (${SIMPLE_EVENTS.join('/')})`;
    if (t.of != null && !PARTICIPANT_GATES.includes(String(t.of))) return `${where}: bad participant gate "of": "${t.of}"`;
    return validateConditionList(t.conditions, `${where} trigger`);
  }
  if (kind === 'dual_event') {
    if (!DUAL_EVENTS.includes(String(t.event))) return `${where}: "${t.event}" is not a dual event (${DUAL_EVENTS.join('/')})`;
    for (const k of ['origin_of', 'destination_of'])
      if (t[k] != null && !PARTICIPANT_GATES.includes(String(t[k]))) return `${where}: bad participant gate "${k}": "${t[k]}"`;
    return validateConditionList(t.origin_conditions, `${where} trigger origin`)
        || validateConditionList(t.destination_conditions, `${where} trigger destination`);
  }
  return `${where}: unknown trigger kind "${kind}"`;
}

// The tracker (standing effects only): the effect's authored lifetime authority.
function validateTracker(t, where) {
  if (t == null) return null;   // absent = the container-existence default
  if (typeof t !== 'object') return `${where}: tracker must be an object`;
  if (!TRACKER_KINDS.includes(String(t.kind || 'container'))) return `${where}: unknown tracker kind "${t.kind}"`;
  return null;
}

// The targets may be a legacy policy string ("targeting_policy") or a native resolver object.
function validateTargets(t, where) {
  if (t == null) return null;
  if (typeof t !== 'object') return `${where}: targets must be an object`;
  const kind = String(t.kind || 'all');
  if (!TARGET_KINDS.includes(kind)) return `${where}: unknown targets kind "${kind}"`;
  if (kind === 'auto') {
    if (!CRITERIA.includes(String(t.criterion || 'nearest'))) return `${where}: bad criterion "${t.criterion}"`;
    if (t.count != null && (!Number.isInteger(t.count) || t.count < 1)) return `${where}: count must be a positive integer`;
  }
  if (kind === 'participant' && !PARTICIPANTS.includes(String(t.participant || 'holder')))
    return `${where}: bad participant "${t.participant}"`;
  return validateConditionList(t.conditions, `${where} targets`);
}

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
    const terr = validateTrigger(e.trigger, where) || validateTargets(e.targets, where);
    if (terr) return terr;
    if (e.targeting_policy && !POLICIES.includes(e.targeting_policy)) return `${where}: bad targeting_policy`;
  } else {
    const terr = validateTrigger(e.trigger, where) || validateTargets(e.targets, where)
        || validateTracker(e.tracker, where);
    if (terr) return terr;
    if (e.targeting_policy && !POLICIES.includes(e.targeting_policy)) return `${where}: bad targeting_policy "${e.targeting_policy}"`;
    if (e.subject && !SUBJECTS.includes(e.subject)) return `${where}: bad subject filter`;
    if (e.attribute && !EFFECT_ATTRS.includes(e.attribute)) return `${where}: bad attribute "${e.attribute}"`;
    const standing = e.trigger && typeof e.trigger === 'object' && e.trigger.kind === 'while';
    if (standing) {
      // Mirrors the game's fail-loud rules (Effect._validate_standing): a standing effect
      // is a continuous stat fold — nothing else is meaningful on it.
      if (!e.attribute) return `${where}: a standing (while) effect needs an attribute to fold`;
      if (e.status && e.status.id) return `${where}: a standing (while) effect cannot apply a status`;
      const tk = e.targets && typeof e.targets === 'object' ? String(e.targets.kind || 'all') : 'all';
      if (!['self','all'].includes(tk)) return `${where}: standing targets must be "self" or "all"`;
    }
    const hasPayload = e.attribute || (e.status && e.status.id);
    if (!hasPayload) return `${where}: effect does nothing — set an attribute change or a status to apply`;
  }
  return validateConditionList(e.conditions, where);
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

// nodeweights deploys as the raw band array, cardsets as the raw multi-card array (the
// game formats), not their editor wrappers.
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
    simpleEvents: SIMPLE_EVENTS,
    dualEvents: DUAL_EVENTS,
    relations: RELATIONS,
    allegiances: ALLEGIANCES,
    participantGates: PARTICIPANT_GATES,
    trackerKinds: TRACKER_KINDS,
    targetKinds: TARGET_KINDS,
    criteria: CRITERIA,
    participants: PARTICIPANTS,
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

// ── model registry ───────────────────────────────────────────────────────────
// Each entry = one generation architecture on the user's ComfyUI server, with its own
// graph builder and defaults. Graph shapes are taken from ComfyUI 0.27's bundled local
// workflow templates (image_krea2_turbo_t2i / image_ideogram4_t2i) and the repo's proven
// Illustrious pipeline (tools/comfy_sdxl_gen.py) — not guessed.
const MODELS = {
  flux2: {
    label: 'Flux 2 dev', steps: 20, guidance: 4.0,
    supportsRef: true, supportsTurbo: true, supportsNegative: false,
  },
  krea2: {
    label: 'Krea 2 Turbo', steps: 8, guidance: 1.0,
    supportsRef: true, supportsTurbo: false, supportsNegative: false,
    // Two distinct ways to steer Krea2 off a reference image — img2img is guaranteed to work
    // (plain latent noising, any architecture); reference is experimental (relies on Krea2
    // sharing Qwen-Image's CLIP/VAE with the Kontext-style ReferenceLatent conditioning trick).
    refModes: [
      { value: 'img2img', label: 'Img2img (denoise controls how much of the reference survives)' },
      { value: 'reference', label: 'Reference latent (experimental — may not transfer to this checkpoint)' },
    ],
  },
  ideogram4: {
    label: 'Ideogram 4', steps: 20, guidance: 7.0,
    supportsRef: false, supportsTurbo: false, supportsNegative: false,
  },
  novacartoon: {
    label: 'NovaCartoonXL (Illustrious)', steps: 30, guidance: 5.0,
    supportsRef: false, supportsTurbo: false, supportsNegative: true,
  },
};

// The shared save tail: plain SaveImage, or background removal (same node both ways).
function saveNodes(imageRef, prefix, rembg) {
  return rembg
    ? { 60: { class_type: 'easy imageRemBg',
              inputs: { images: imageRef, rem_mode: 'Inspyrenet', image_output: 'Save',
                        save_prefix: prefix, torchscript_jit: false, add_background: 'none',
                        refine_foreground: true } } }
    : { 60: { class_type: 'SaveImage', inputs: { images: imageRef, filename_prefix: prefix } } };
}

// Krea 2 Turbo: simple KSampler graph — qwen3vl text encoder (type krea2), qwen_image VAE,
// zeroed-out negative, cfg ~1 at 8 steps (euler/simple).
//
// Two optional reference paths, picked by refMode when refName is set:
//   'img2img'    — LoadImage → ImageScale → VAEEncode feeds the *starting latent* instead of
//                  EmptyLatentImage, with denoise < 1 controlling how much of it survives.
//                  Architecture-agnostic, guaranteed to work on any checkpoint.
//   'reference'  — the Flux 2 Kontext trick (LoadImage → ImageScale → VAEEncode →
//                  ReferenceLatent onto the positive conditioning). Experimental: it rides
//                  Krea2 sharing Qwen-Image's CLIP/VAE, not a confirmed-supported path.
function buildKrea2Workflow(prompt, w, h, steps, cfg, seed, prefix, rembg, refName, refMode, denoise) {
  const useImg2Img = !!refName && refMode === 'img2img';
  const useReference = !!refName && refMode === 'reference';

  const latentNodes = useImg2Img ? {
    70: { class_type: 'LoadImage', inputs: { image: refName } },
    71: { class_type: 'ImageScale', inputs: { image: ['70', 0], width: w, height: h, upscale_method: 'lanczos', crop: 'disabled' } },
    34: { class_type: 'VAEEncode', inputs: { pixels: ['71', 0], vae: ['12', 0] } },
  } : {
    34: { class_type: 'EmptyLatentImage', inputs: { width: w, height: h, batch_size: 1 } },
  };

  const referenceNodes = useReference ? {
    80: { class_type: 'LoadImage', inputs: { image: refName } },
    81: { class_type: 'ImageScale', inputs: { image: ['80', 0], width: w, height: h, upscale_method: 'lanczos', crop: 'disabled' } },
    82: { class_type: 'VAEEncode', inputs: { pixels: ['81', 0], vae: ['12', 0] } },
    83: { class_type: 'ReferenceLatent', inputs: { conditioning: ['20', 0], latent: ['82', 0] } },
  } : {};
  const positive = useReference ? ['83', 0] : ['20', 0];

  return Object.assign(saveNodes(['50', 0], prefix, rembg), latentNodes, referenceNodes, {
    10: { class_type: 'UNETLoader', inputs: { unet_name: 'krea2_turbo_bf16.safetensors', weight_dtype: 'default' } },
    11: { class_type: 'CLIPLoader', inputs: { clip_name: 'qwen3vl_4b_bf16.safetensors', type: 'krea2' } },
    12: { class_type: 'VAELoader', inputs: { vae_name: 'qwen_image_vae.safetensors' } },
    20: { class_type: 'CLIPTextEncode', inputs: { text: prompt, clip: ['11', 0] } },
    21: { class_type: 'ConditioningZeroOut', inputs: { conditioning: ['20', 0] } },
    40: { class_type: 'KSampler',
          inputs: { model: ['10', 0], positive, negative: ['21', 0], latent_image: ['34', 0],
                    seed, steps, cfg, sampler_name: 'euler', scheduler: 'simple',
                    denoise: useImg2Img ? (denoise == null ? 0.6 : denoise) : 1.0 } },
    50: { class_type: 'VAEDecode', inputs: { samples: ['40', 0], vae: ['12', 0] } },
  });
}

// Ideogram 4: asymmetric CFG — a conditional and a dedicated unconditional diffusion model
// feed a DualModelGuider (cfg on `guidance`), the conditional side wrapped in a CFGOverride
// that drops cfg to 3 for the last 30% of the schedule; Ideogram4Scheduler Default preset
// (mu 0.0, std 1.75); flux2 VAE.
function buildIdeogram4Workflow(prompt, w, h, steps, cfg, seed, prefix, rembg) {
  return Object.assign(saveNodes(['50', 0], prefix, rembg), {
    10: { class_type: 'UNETLoader', inputs: { unet_name: 'ideogram4_fp8_scaled.safetensors', weight_dtype: 'default' } },
    13: { class_type: 'UNETLoader', inputs: { unet_name: 'ideogram4_unconditional_fp8_scaled.safetensors', weight_dtype: 'default' } },
    11: { class_type: 'CLIPLoader', inputs: { clip_name: 'qwen3vl_8b_fp8_scaled.safetensors', type: 'ideogram4' } },
    12: { class_type: 'VAELoader', inputs: { vae_name: 'flux2-vae.safetensors' } },
    20: { class_type: 'CLIPTextEncode', inputs: { text: prompt, clip: ['11', 0] } },
    21: { class_type: 'ConditioningZeroOut', inputs: { conditioning: ['20', 0] } },
    22: { class_type: 'CFGOverride', inputs: { model: ['10', 0], cfg: 3.0, start_percent: 0.7, end_percent: 1.0 } },
    30: { class_type: 'DualModelGuider',
          inputs: { model: ['22', 0], positive: ['20', 0], cfg,
                    model_negative: ['13', 0], negative: ['21', 0] } },
    31: { class_type: 'KSamplerSelect', inputs: { sampler_name: 'euler' } },
    32: { class_type: 'Ideogram4Scheduler', inputs: { steps, width: w, height: h, mu: 0.0, std: 1.75 } },
    33: { class_type: 'RandomNoise', inputs: { noise_seed: seed } },
    34: { class_type: 'EmptyFlux2LatentImage', inputs: { width: w, height: h, batch_size: 1 } },
    40: { class_type: 'SamplerCustomAdvanced',
          inputs: { noise: ['33', 0], guider: ['30', 0], sampler: ['31', 0], sigmas: ['32', 0],
                    latent_image: ['34', 0] } },
    50: { class_type: 'VAEDecode', inputs: { samples: ['40', 0], vae: ['12', 0] } },
  });
}

// Booru-style SDXL quality enhancers (the repo's proven Illustrious convention —
// see tools/comfy_sdxl_gen.py).
const SDXL_POS_PREFIX = 'masterpiece, best quality, high quality, ';
const SDXL_NEG_DEFAULT = 'worst quality, low quality, lowres, bad anatomy, bad hands, ' +
  'missing fingers, extra digits, fewer digits, jpeg artifacts, ' +
  'signature, watermark, username, text, blurry, deformed';
const NOVACARTOON_CKPT = 'ssdd_illustrious\\novaCartoonXL_v60.safetensors';

// SDXL trains on ~1MP buckets — map the per-type canvases onto the nearest native size
// by aspect so an Illustrious render never runs at Flux resolutions.
function sdxlSize(w, h) {
  const aspect = w / h;
  if (aspect > 1.15) return [1216, 832];
  if (aspect < 0.87) return [832, 1216];
  return [1024, 1024];
}

// NovaCartoonXL (Illustrious): classic SDXL checkpoint graph — clip-skip 2, quality
// prefix, real negative prompt, euler_ancestral/normal, baked VAE.
function buildNovaCartoonWorkflow(prompt, negative, w, h, steps, cfg, seed, prefix, rembg) {
  const [sw, sh] = sdxlSize(w, h);
  return Object.assign(saveNodes(['50', 0], prefix, rembg), {
    10: { class_type: 'CheckpointLoaderSimple', inputs: { ckpt_name: NOVACARTOON_CKPT } },
    11: { class_type: 'CLIPSetLastLayer', inputs: { clip: ['10', 1], stop_at_clip_layer: -2 } },
    20: { class_type: 'CLIPTextEncode', inputs: { text: SDXL_POS_PREFIX + prompt, clip: ['11', 0] } },
    21: { class_type: 'CLIPTextEncode', inputs: { text: negative || SDXL_NEG_DEFAULT, clip: ['11', 0] } },
    34: { class_type: 'EmptyLatentImage', inputs: { width: sw, height: sh, batch_size: 1 } },
    40: { class_type: 'KSampler',
          inputs: { model: ['10', 0], positive: ['20', 0], negative: ['21', 0], latent_image: ['34', 0],
                    seed, steps, cfg, sampler_name: 'euler_ancestral', scheduler: 'normal', denoise: 1.0 } },
    50: { class_type: 'VAEDecode', inputs: { samples: ['40', 0], vae: ['10', 2] } },
  });
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

// ── reference catalog: existing card art ranked by composition affinity ──────
// The current card's composition (elements + chess_pieces, both multisets — pieces
// repeat, e.g. bishop_bishop) ranks every OTHER card that has art:
//   tier 0 — the "bare piece version": identical piece multiset, no elements.
//   tier 1 — pure subsets of the composition (no foreign components),
//            best shared-component count first, pieces weighted over elements.
//   tier 2 — everything else (has components this card lacks), same score,
//            fewer foreign components first. Offered, never excluded.
function multisetCounts(arr) {
  const m = new Map();
  for (const x of arr || []) m.set(x, (m.get(x) || 0) + 1);
  return m;
}
function multisetShared(a, b) {
  let n = 0;
  for (const [k, c] of a) n += Math.min(c, b.get(k) || 0);
  return n;
}
function multisetSize(m) { let n = 0; for (const c of m.values()) n += c; return n; }

// Resolve a repo-relative game-art path (as handed out by rankCardReferences / the
// /gameart route) to an absolute path — same validation as serving it.
function gameArtAbs(rel) {
  rel = String(rel || '');
  if (rel.includes('..') || !rel.startsWith('assets/') || !rel.endsWith('.png')) return null;
  const abs = path.join(GAME_ROOT, rel);
  return fs.existsSync(abs) ? abs : null;
}

function rankCardReferences(elements, pieces, excludeId) {
  const curE = multisetCounts(elements), curP = multisetCounts(pieces);
  const curPieceCount = multisetSize(curP);
  const refs = [];
  for (const e of listGameEntries('card', true)) {
    if (e.id === excludeId) continue;
    const art = gameArtRel('card', e.id, e.data);
    if (!art) continue;
    const candE = multisetCounts(e.data.elements), candP = multisetCounts(e.data.chess_pieces);
    const sharedP = multisetShared(curP, candP), sharedE = multisetShared(curE, candE);
    const foreign = (multisetSize(candP) - sharedP) + (multisetSize(candE) - sharedE);
    const barePieceVersion = foreign === 0 && sharedE === 0 && multisetSize(candE) === 0
      && sharedP === curPieceCount && multisetSize(candP) === curPieceCount && curPieceCount > 0;
    const tier = barePieceVersion ? 0 : (foreign === 0 ? 1 : 2);
    refs.push({
      id: e.id, name: e.data.display_name || e.id, art,
      elements: e.data.elements || [], chess_pieces: e.data.chess_pieces || [],
      enemy: !!e.data.enemy_only,
      _tier: tier, _score: 2 * sharedP + sharedE, _foreign: foreign,
    });
  }
  refs.sort((a, b) => a._tier - b._tier || b._score - a._score
    || a._foreign - b._foreign || (a.id < b.id ? -1 : 1));
  return refs.map(({ _tier, _score, _foreign, ...r }) => r);
}

// ── LLM art prompts (local Ollama) ───────────────────────────────────────────
// The LLM reads the item's FULL data (the same plain-English summary the editor shows)
// and translates mechanics into imagery. The hard rules the plain auto-prompt encodes
// (never "card"/"tcg", never rules text in the scene) are enforced by instruction here.
const LLM_SYSTEM_PROMPT = [
  'You write prompts for an image-generation model that illustrates fantasy game pieces.',
  'Given a game item\'s data, respond with exactly ONE image prompt: a single vivid subject',
  'or scene as comma-separated visual phrases, under 60 words.',
  'Hard rules:',
  '- Translate game mechanics into visual motifs (poison → dripping green venom, healing →',
  '  soft radiant glow, speed → wind-blurred motion). Never quote or restate rules text.',
  '- Never use the words: card, TCG, trading card, frame, border, stats, icon, UI, text.',
  '- The scene must contain no readable text, letters, numbers, or lettering of any kind.',
  '- If you are given an example prompt, it defines STAGING ONLY: subject framing,',
  '  centered-object vs full-scene, plain background for cutouts. Never reuse its wording,',
  '  style adjectives, lighting or background phrases — invent imagery specific to this item.',
  '- Output only the prompt itself — no preamble, no options, no quotation marks.',
].join('\n');

// When reference illustrations ride along (advanced mode), the model sees the actual
// pixels — gemma4:31b is vision-capable — plus an instruction to match style, not subject.
const LLM_VISION_ADDENDUM =
  'You are shown reference illustrations from the same game. Match their rendering style, ' +
  'palette, and level of detail — do NOT copy their subjects.';

// One /api/generate round-trip. Returns the parsed body; throws on transport failure.
async function ollamaGenerate(body) {
  const s = getSettings();
  const base = (s.ollamaUrl || 'http://127.0.0.1:11434').replace(/\/$/, '');
  let res;
  try {
    res = await fetch(base + '/api/generate', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.assign({ model: s.llmModel || 'gemma4:31b', stream: false, think: false }, body)),
    });
  } catch (e) { throw new Error(`Ollama unreachable at ${base} — is it running?`); }
  if (!res.ok) {
    const detail = await res.text();
    const err = new Error(`Ollama request failed: HTTP ${res.status} ${detail.slice(0, 500)}`);
    err.httpStatus = res.status;
    throw err;
  }
  return res.json();
}

// ── cloud providers ──────────────────────────────────────────────────────────
// Same request shape as ollamaGenerate ({system, prompt, images?, options}), same
// {response} result, so every ✨ feature routes through llmGenerate unchanged. The
// cloud adapters ignore body.model and Ollama's sampling options: one configured
// model per provider serves all features, and the current cloud flagships reject
// temperature-style knobs anyway. Clients are lazy so the SDKs only load (and read
// their credentials) when the provider is actually selected.

let _claude = null;
async function claudeGenerate(body) {
  const s = getSettings();
  if (!_claude) {
    const Anthropic = require('@anthropic-ai/sdk');
    try {
      _claude = new Anthropic();   // credentials: ANTHROPIC_API_KEY or an `ant auth login` profile
    } catch (e) {
      throw new Error(`Claude auth not configured — run \`ant auth login\` or set ANTHROPIC_API_KEY, then restart the Tool (${e.message})`);
    }
  }
  const content = (body.images || []).map(img =>
    ({ type: 'image', source: { type: 'base64', media_type: 'image/png', data: img } }));
  content.push({ type: 'text', text: body.prompt });
  let msg;
  try {
    msg = await _claude.messages.create({
      model: s.claudeModel || 'claude-opus-4-8',
      max_tokens: 8192,   // headroom for adaptive thinking; billed only as generated
      thinking: { type: 'adaptive' },
      system: body.system,
      messages: [{ role: 'user', content }],
    });
  } catch (e) {
    if (e.status === 401)
      throw new Error('Claude auth failed — run `ant auth login` or set ANTHROPIC_API_KEY, then restart the Tool');
    throw new Error(`Claude request failed: ${e.message}`);
  }
  const text = (msg.content || []).filter(b => b.type === 'text').map(b => b.text).join('');
  return { response: text };
}

let _openai = null;
async function openaiGenerate(body) {
  const s = getSettings();
  if (!_openai) {
    const OpenAI = require('openai');
    try {
      _openai = new OpenAI();   // credentials: OPENAI_API_KEY (OpenAI has no login flow for API use)
    } catch (e) {
      throw new Error(`ChatGPT auth not configured — set OPENAI_API_KEY, then restart the Tool (${e.message})`);
    }
  }
  const content = [{ type: 'input_text', text: body.prompt }];
  for (const img of body.images || [])
    content.push({ type: 'input_image', image_url: 'data:image/png;base64,' + img });
  let rsp;
  try {
    rsp = await _openai.responses.create({
      model: s.openaiModel || 'gpt-5.5',
      instructions: body.system,
      input: [{ role: 'user', content }],
      max_output_tokens: 8192,
    });
  } catch (e) {
    if (e.status === 401)
      throw new Error('ChatGPT auth failed — check OPENAI_API_KEY, then restart the Tool');
    throw new Error(`ChatGPT request failed: ${e.message}`);
  }
  // output_text is the SDK convenience getter; scan the output array as a fallback.
  let text = rsp.output_text || '';
  if (!text) {
    for (const item of rsp.output || [])
      for (const c of item.content || [])
        if (c.type === 'output_text') text += c.text;
  }
  return { response: text };
}

// ── Claude Code provider: rides the user's EXISTING Claude subscription ──────
// Shells out to the locally installed Claude Code CLI in headless print mode
// (`claude -p`), so ✨ calls use the same login and limits as the user's normal
// Claude Code sessions — no API key, no per-token developer-platform billing.
// The prompt travels via stdin and the system prompt via a temp file, so model
// text never touches shell quoting. Reference images are written to workspace
// tmp files the CLI views with its Read tool (the only tool allowed; print
// mode auto-denies the rest).
const { spawn: spawnProc } = require('child_process');

async function claudeCodeGenerate(body) {
  const s = getSettings();
  const model = String(s.claudeCodeModel || '').trim();
  if (model && !/^[\w.:-]+$/.test(model)) throw new Error(`bad Claude Code model "${model}"`);
  // per-call temp dir: parallel calls (batch recipe inference) must not clobber
  // each other's system/reference files
  const tmpDir = path.join(WORKSPACE, 'tmp', `${Date.now()}_${Math.floor(Math.random() * 1e6)}`);
  ensureDir(tmpDir);
  const sysFile = path.join(tmpDir, 'claude_system.txt');
  fs.writeFileSync(sysFile, String(body.system || ''));
  const promptParts = [body.prompt];
  (body.images || []).forEach((img, i) => {
    const p = path.join(tmpDir, `claude_ref_${i}.png`);
    fs.writeFileSync(p, Buffer.from(img, 'base64'));
    promptParts.push(`Reference image ${i + 1} — view it with the Read tool: ${p}`);
  });
  const cmd = [String(s.claudeCliCmd || 'claude'), '-p', '--output-format', 'text',
    '--system-prompt-file', `"${sysFile}"`, '--allowedTools', 'Read', '--add-dir', `"${tmpDir}"`]
    .concat(model ? ['--model', model] : []).join(' ');
  return new Promise((resolve, reject) => {
    // a stray API key/token in the env would silently reroute the CLI onto
    // per-token API billing — the whole point of this provider is the subscription
    const env = Object.assign({}, process.env);
    delete env.ANTHROPIC_API_KEY;
    delete env.ANTHROPIC_AUTH_TOKEN;
    const child = spawnProc(cmd, { shell: true, env, windowsHide: true });
    let out = '', errOut = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('Claude Code timed out after 240s'));
    }, 240000);
    child.stdout.on('data', c => out += c);
    child.stderr.on('data', c => errOut += c);
    child.on('error', e => {
      clearTimeout(timer);
      reject(new Error(`Claude Code CLI not runnable (${e.message}) — is \`claude\` installed?`));
    });
    child.on('close', code => {
      clearTimeout(timer);
      try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { /* best-effort */ }
      if (code !== 0) {
        const detail = (errOut || out).slice(0, 400);
        if (/log ?in|auth|credential/i.test(detail))
          return reject(new Error(`Claude Code is not logged in — run \`claude\` in a terminal and /login once (${detail})`));
        return reject(new Error(`Claude Code failed (exit ${code}): ${detail}`));
      }
      resolve({ response: out });
    });
    child.stdin.end(promptParts.join('\n'));
  });
}

// THE provider switch: every ✨ feature calls this, the settings decide who answers.
async function llmGenerate(body) {
  switch (getSettings().llmProvider || 'ollama') {
    case 'claude-code': return claudeCodeGenerate(body);
    case 'claude':      return claudeGenerate(body);
    case 'openai':      return openaiGenerate(body);
    default:            return ollamaGenerate(body);
  }
}

// One vision generation with the multi-image crash fallback. Some model runners
// (gemma4:31b on current Ollama) crash on MULTI-image requests while handling single
// images fine — on failure, describe each image's style in its own single-image call,
// then synthesize text-only from the notes. Shared by the ✨ art-prompt writer and
// the ✨ recipe inference.
async function llmVisionGenerate({ system, prompt, images, options }) {
  if (!images || !images.length) return llmGenerate({ system, prompt, options });
  try {
    return await llmGenerate({ system: system + '\n' + LLM_VISION_ADDENDUM, prompt, images, options });
  } catch (e) {
    if (images.length === 1) {
      if (/image|vision|multimodal/i.test(e.message))
        throw new Error(`the configured LLM can't read images — pick a vision-capable model in Settings (${e.message.slice(0, 200)})`);
      throw e;
    }
    const notes = [];
    for (const img of images) {
      const d = await llmGenerate({
        system: 'Describe the visual STYLE of this illustration in one sentence: medium, ' +
                'palette, lighting, rendering technique. Do NOT describe the subject.',
        prompt: 'Style:', images: [img],
        options: { temperature: 0.3, num_predict: 80 },
      });
      const line = String(d.response || '').replace(/\s*\n+\s*/g, ' ').trim();
      if (line) notes.push(line);
    }
    return llmGenerate({
      system: system + '\nWrite the prompt so the result matches the reference ' +
              'style notes you are given — they describe illustrations from the same game.',
      prompt: prompt + '\nReference style notes:\n' + notes.map(n => '- ' + n).join('\n'),
      options,
    });
  }
}

async function llmArtPrompt(typeLabel, name, summary, example, refImages, concept, refHint, guides) {
  const user = [
    `Item type: ${typeLabel}`,
    `Name: ${name}`,
    ...(guides || []),   // opt-in authored composition direction (authoritative)
    'Item data:',
    ...(summary || []).map(l => '- ' + l),
    example ? `Example prompt for this item type (staging only — do not copy its wording): ${example}` : '',
    // optional creative direction from the user, verbatim
    concept ? `Concept direction (follow this): ${concept}` : '',
    (refHint && refImages && refImages.length) ? `How to use the reference illustrations: ${refHint}` : '',
  ].filter(Boolean).join('\n');
  const out = await llmVisionGenerate({ system: LLM_SYSTEM_PROMPT, prompt: user,
    images: refImages, options: { temperature: 0.9, num_predict: 200 } });
  return cleanLlmPrompt(out);
}

// LLM responses arrive with thinking remnants / labels / quotes — reduce to the bare prompt.
function cleanLlmPrompt(out) {
  const text = String(out.response || '')
    .replace(/<think>[\s\S]*?<\/think>/g, '')      // thinking remnants, if the flag is ignored
    .replace(/^\s*(?:prompt\s*:)?\s*/i, '')        // "Prompt:" label prefixes
    .replace(/\s*\n+\s*/g, ' ')
    .replace(/^["'`*]+|["'`*]+$/g, '')   // incl. markdown *emphasis* wrapping (Claude Code)
    .trim();
  if (!text) throw new Error('the LLM returned an empty prompt');
  return text;
}

// Vision-analyze the item's CURRENT art and write a prompt that would recreate it —
// for regenerating faithful variations of art the user already likes. Single-image
// call, so it works on runners with the multi-image crash (gemma4:31b).
const LLM_MATCH_SYSTEM_PROMPT = [
  'You write prompts for an image-generation model. You are shown an existing illustration',
  'from a fantasy game. Respond with exactly ONE image prompt that would faithfully recreate',
  'it: subject, pose, composition, palette, lighting, rendering style — comma-separated',
  'visual phrases, under 60 words.',
  'If the request includes concept direction or guidance on how to use the illustration,',
  'follow it — deviate from faithful recreation exactly where it tells you to.',
  'Hard rules:',
  '- Never use the words: card, TCG, trading card, frame, border, stats, icon, UI, text.',
  '- The prompt must not ask for readable text, letters, or numbers in the scene.',
  '- Output only the prompt itself — no preamble, no commentary, no quotation marks.',
].join('\n');

async function llmPromptFromArt(type, id, concept, refHint, guides) {
  const abs = currentArtAbs(type, id);
  if (!abs) throw new Error('this item has no current art to analyze');
  const user = [
    'Write the prompt that recreates this illustration.',
    ...(guides || []),   // opt-in authored composition direction (authoritative)
    // the same optional guidance inputs the ✨ writer honors — here the analyzed
    // image IS the reference, so the ref hint applies unconditionally
    concept ? `Concept direction (follow this, adjusting the recreation toward it): ${concept}` : '',
    refHint ? `How to use the illustration as a reference: ${refHint}` : '',
  ].filter(Boolean).join('\n');
  const out = await llmGenerate({
    system: LLM_MATCH_SYSTEM_PROMPT,
    prompt: user,
    images: [fs.readFileSync(abs).toString('base64')],
    options: { temperature: 0.4, num_predict: 200 },
  });
  return cleanLlmPrompt(out);
}

// ── ✨ recipe inference: fill a card's art recipe from its FAMILY ─────────────
// The user authors nothing: piece-relatives supply the CONCEPT (what the subject IS —
// bishop_rook is consulted before anything else for darkness_earth_bishop_rook), and
// element-relatives supply the THEME (how it is dressed — darkness_earth_pawn et al).
// Each relative contributes its stored recipe prompt when it has one (free, exact) and
// its actual art as a vision reference otherwise. The synthesized result is an ordinary
// tool.art recipe: prompt + the closest relative's art as the generation reference.

// Array flavor of the multiset-overlap count (rankCardReferences' multisetShared
// works on Maps of counts — do NOT reuse that name, it shadows globally).
function sharedIdCount(a, b) {
  const pool = [...b];
  let n = 0;
  for (const x of a) {
    const i = pool.indexOf(x);
    if (i >= 0) { pool.splice(i, 1); n++; }
  }
  return n;
}

// A hand-picked theme reference → a theme-pool entry (stored prompt and/or art). Null
// when the card is missing, is the target itself, or teaches nothing.
function themeRefEntry(id, excludeId) {
  if (id === excludeId) return null;
  const e = findGameEntry('card', id);
  if (!e) return null;
  const ta = e.data.tool && e.data.tool.art;
  const prompt = (ta && (ta.prompt || (ta.last && ta.last.prompt))) || null;
  const art = gameArtRel('card', e.id, e.data);
  if (!prompt && !art) return null;
  return { id: e.id, data: e.data, prompt, art, sp: 0, se: 1, bare: false, exactEls: false };
}

// The two relative pools, best-first. Only cards that can TEACH something (a stored
// recipe prompt or deployed art) count; enemy fodder is excluded (own art style).
function inferRelatives(entry) {
  const els = entry.data.elements || [];
  const pieces = entry.data.chess_pieces || [];
  const scored = [];
  for (const e of listGameEntries('card')) {
    if (e.id === entry.id || e.data.enemy_only) continue;
    const cEls = e.data.elements || [];
    const cPieces = e.data.chess_pieces || [];
    const ta = e.data.tool && e.data.tool.art;
    const prompt = (ta && (ta.prompt || (ta.last && ta.last.prompt))) || null;
    const art = gameArtRel('card', e.id, e.data);
    if (!prompt && !art) continue;
    const sp = sharedIdCount(pieces, cPieces), se = sharedIdCount(els, cEls);
    if (!sp && !se) continue;
    scored.push({ id: e.id, data: e.data, prompt, art, sp, se,
      // the bare piece version (same pieces, no elements) is the concept anchor
      bare: pieces.length > 0 && sp === pieces.length && cPieces.length === pieces.length && !cEls.length,
      exactEls: els.length > 0 && se === els.length && cEls.length === els.length });
  }
  const concept = scored.filter(r => r.sp > 0)
    .sort((a, b) => (b.bare - a.bare) || (b.sp - a.sp) || (a.se - b.se) || a.id.localeCompare(b.id))
    .slice(0, 3);
  const inConcept = new Set(concept.map(r => r.id));
  const theme = scored.filter(r => r.se > 0 && !inConcept.has(r.id))
    .sort((a, b) => (b.exactEls - a.exactEls) || (b.se - a.se) || (b.sp - a.sp) || a.id.localeCompare(b.id))
    .slice(0, 3);
  // kinThemeMode 'select': the hand-picked references REPLACE the auto element-family
  // theme. Concept (piece side) is untouched. Empty / unusable picks fall back to family.
  const s = getSettings();
  if (s.kinThemeMode === 'select' && Array.isArray(s.kinThemeRefs) && s.kinThemeRefs.length) {
    const picked = s.kinThemeRefs.map(id => themeRefEntry(id, entry.id)).filter(Boolean).slice(0, 4);
    if (picked.length) return { concept, theme: picked };
  }
  return { concept, theme };
}

// THE concept anchor for a card: its own current art when it has any (regeneration
// keeps identity), else the bare piece version's art (bishop_rook for
// darkness_earth_bishop_rook), else the closest piece-relative with art.
function resolveAnchor(entry) {
  // kinAnchorMode 'base' skips the card's own art and anchors straight on the base unit
  // (the bare piece version), even when the card already has art.
  const own = (getSettings().kinAnchorMode === 'base') ? null : currentArtAbs('card', entry.id);
  if (own) return { id: entry.id, abs: own, ref: { source: 'current' } };
  const { concept } = inferRelatives(entry);
  const cand = concept.find(r => r.bare && r.art) || concept.find(r => r.art);
  if (cand) return { id: cand.id, abs: path.join(GAME_ROOT, cand.art),
    ref: { source: 'game', path: cand.art, name: cand.data.display_name || cand.id } };
  return null;
}

// Adherence = WHICH INSTRUCTIONS the prompt-writing LLM gets (the user's mental model,
// settled over a long discussion). The question each mode answers is: WHAT carries
// over from the anchor image?
//   replicate — the PICTURE carries: subject, pose, framing; only materials/palette/
//               lighting re-themed. For re-rendering art you already like.
//   concept   — the DESIGN carries (THE DEFAULT): the same recognizable character —
//               anatomy, signature features, attire — but a freshly invented
//               presentation (pose, action, camera, scene) staged for the theme.
//   free      — the IDEA carries: loose family blend, no anchor lock.
// No anchor art anywhere → falls back to free (reported via stats.mode).
async function llmInferRecipe(entry, adherence) {
  const alias = { faithful: 'replicate', subject: 'concept' };   // pre-rename names
  adherence = alias[adherence] || adherence;
  adherence = ['replicate', 'concept', 'free'].includes(adherence) ? adherence : 'concept';
  const anchor = adherence === 'free' ? null : resolveAnchor(entry);
  if (adherence !== 'free' && !anchor) adherence = 'free';
  if (adherence !== 'free') return llmInferAnchored(entry, anchor, adherence);
  return llmInferBlend(entry);
}

async function llmInferAnchored(entry, anchor, adherence) {
  const started = Date.now();
  const d = entry.data;
  const { theme } = inferRelatives(entry);
  const images = [fs.readFileSync(anchor.abs).toString('base64')];
  const themeLines = [];
  // Anonymous role labels only — never a relative id (it spells out the composition). A
  // relative's stored prompt is a good example for the family, so it rides along verbatim.
  let tn = 0;
  for (const r of theme) {
    if (r.id === anchor.id) continue;
    tn++;
    if (r.prompt) themeLines.push(`- theme example ${tn}: "${r.prompt}"`);
    else if (r.art && images.length < 3) {
      images.push(fs.readFileSync(path.join(GAME_ROOT, r.art)).toString('base64'));
      themeLines.push(`- theme example ${tn}: see reference image ${images.length}`);
    }
  }
  // "the theme" — never the element names. The look is shown by the theme examples and
  // their reference art; naming the elements is the leak we are closing.
  const task = adherence === 'replicate'
    ? "Describe reference image 1 faithfully — the subject, its pose, the framing and composition — and re-dress it in the theme shown by the examples below: replace ONLY materials, palette, lighting and magical effects. The result must read as the SAME illustration, re-themed."
    : "Inventory what makes the subject of reference image 1 recognizable — creature type, build, anatomy, signature features, attire and equipment — and carry ALL of those identifying details into the prompt. Then stage it FRESH: invent a new pose, action, camera angle and setting that express the theme shown by the examples below, with materials and palette rendered in that theme. Same recognizable character, new presentation — do not copy the reference's pose or composition.";
  const user = [
    // Authored name = concept + theme identity ("Lightning Hierophant"); name only, never
    // the composition-encoding id (see llmInferBlend).
    d.display_name ? `Card name (the authored concept + theme identity — honor it): ${d.display_name}` : '',
    ...artGuideLines(d.elements, d.chess_pieces),   // opt-in authored composition direction
    ...steerLines(),                                 // always-on free-text steering
    'Reference image 1 is THE CONCEPT — the exact subject this card\'s art must depict.',
    themeLines.length ? 'THEME examples (how this theme looks in this game — palette, materials, magic; match it, do not name it):' : '',
    ...themeLines,
    task,
    'Do not name any element, material family, or chess piece — describe only what is seen.',
  ].filter(Boolean).join('\n');
  const out = await llmVisionGenerate({
    system: LLM_SYSTEM_PROMPT +
      '\nYou are re-theming an existing illustration: reference image 1 is the concept anchor.' +
      ' Carry its specifics into the prompt as instructed — do not reinterpret the subject,' +
      ' and never name an element or chess piece.',
    prompt: user, images, options: { temperature: 0.6, num_predict: 220 },
  });
  const recipe = { prompt: cleanLlmPrompt(out), ref: Object.assign({}, anchor.ref) };
  recipe.inferredFrom = { anchor: anchor.id, theme: theme.map(r => r.id), mode: adherence };
  recipe.stats = { mode: adherence, relatives: theme.length + 1,
    prompts: theme.filter(r => r.prompt).length, images: images.length, ms: Date.now() - started };
  return recipe;
}

async function llmInferBlend(entry) {
  const started = Date.now();
  const d = entry.data;
  const { concept, theme } = inferRelatives(entry);
  if (!concept.length && !theme.length)
    throw new Error('no related cards with art or stored prompts to infer from');
  // Vision references are the expensive part (full-size card art per image) — stored
  // prompts are free and exact, so the more prompts the family already carries, the
  // fewer images ride along: 0 prompts → up to 3 images … 3+ prompts → text-only.
  // Budgeting: theme images outrank concept images (palette/materials are the visual
  // signal; concepts describe well in text), and a pool with entries but no stored
  // prompts always gets at least one image so it isn't silently dropped.
  const promptCount = [...concept, ...theme].filter(r => r.prompt).length;
  const imgCap = Math.max(0, 3 - promptCount);
  const imgWorthy = r => !r.prompt && r.art;
  const order = [];
  for (let k = 0; k < 3; k++) {   // theme-first interleave
    if (theme[k] && imgWorthy(theme[k])) order.push(theme[k]);
    if (concept[k] && imgWorthy(concept[k])) order.push(concept[k]);
  }
  const chosen = new Set();
  for (const r of order) if (chosen.size < imgCap) chosen.add(r.id);
  for (const list of [concept, theme])
    if (list.length && !list.some(r => r.prompt || chosen.has(r.id))) {
      const best = list.find(imgWorthy);
      if (best) chosen.add(best.id);
    }
  const images = [];
  const conceptLines = [], themeLines = [];
  // Relatives are referenced by ANONYMOUS role labels, never by id — an id like
  // "air_fire_bishop_queen" spells out the composition and taught the LLM to draw a chess
  // bishop/queen. A relative's stored prompt IS an example of good art for the family, so
  // it rides along verbatim; only the composition-encoding id is withheld.
  for (const [list, out, role] of [[concept, conceptLines, 'concept'], [theme, themeLines, 'theme']]) {
    let n = 0;
    for (const r of list) {
      n++;
      if (r.prompt) out.push(`- ${role} relative ${n}: "${r.prompt}"`);
      else if (chosen.has(r.id)) {
        images.push(fs.readFileSync(path.join(GAME_ROOT, r.art)).toString('base64'));
        out.push(`- ${role} relative ${n}: see reference image ${images.length}`);
      }
    }
  }
  // The card is described by its family alone — NEVER by naming its own elements or pieces
  // (that is the leak). CONCEPT relatives show what the subject is; THEME relatives (and
  // their reference art) carry the look. No composition word appears anywhere in the input.
  const user = [
    // The AUTHORED name carries the concept + theme identity ("Lightning Hierophant") —
    // the one signal the family art can't convey. Name only, NEVER the id (the id spells
    // out the composition and is the leak); omit the line when there is no display name.
    d.display_name ? `Card name (the authored concept + theme identity — honor it): ${d.display_name}` : '',
    ...artGuideLines(d.elements, d.chess_pieces),   // opt-in authored composition direction
    ...steerLines(),                                 // always-on free-text steering
    d.description ? `Card text (flavor context only — never render text): ${d.description}` : '',
    conceptLines.length ? 'CONCEPT relatives — they show what the SUBJECT is:' : '',
    ...conceptLines,
    themeLines.length ? 'THEME relatives — they show the LOOK (palette, materials, magic); match it from their art/description, do not name it:' : '',
    ...themeLines,
    'Write ONE image prompt: the concept subject rendered in the theme look. Do not name any element, material family, or chess piece — describe only what is seen.',
  ].filter(Boolean).join('\n');
  const out = await llmVisionGenerate({
    system: LLM_SYSTEM_PROMPT +
      "\nYou are inferring the prompt from the card's FAMILY: relatives are grouped as CONCEPT" +
      ' (the subject) and THEME (the look). Blend them — never copy a relative' +
      "'s prompt verbatim, and never name an element or chess piece.",
    prompt: user, images, options: { temperature: 0.8, num_predict: 200 },
  });
  const recipe = { prompt: cleanLlmPrompt(out) };
  // generation reference: the closest relative that has art — keeps the family look
  const refCand = [...concept, ...theme].find(r => r.art);
  if (refCand) recipe.ref = { source: 'game', path: refCand.art, name: refCand.data.display_name || refCand.id };
  recipe.inferredFrom = { concept: concept.map(r => r.id), theme: theme.map(r => r.id) };
  // what this inference actually cost — surfaced in the UI so slowness is explainable
  recipe.stats = { mode: 'free', relatives: concept.length + theme.length, prompts: promptCount,
    images: images.length, ms: Date.now() - started };
  return recipe;
}

// ── ✨ recipe inference JOBS ──────────────────────────────────────────────────
// Batch inference runs server-side as a polled job (like art generation): the browser
// starting it can re-render, navigate, even reload — progress lives here, one job per
// file at a time, and /api/state lists running jobs so a fresh page reattaches.
const inferJobs = {};   // jobId -> { id, file, status, total, done, results, error, startedAt }
let inferSeq = 1;
function inferJobForFile(file) {
  return Object.values(inferJobs).find(j => j.file === file && j.status === 'running') || null;
}

// Persists one inferred recipe onto its entry (stats stay response-only telemetry).
function persistRecipe(entry, recipe) {
  const stats = recipe.stats;
  delete recipe.stats;
  const data = JSON.parse(JSON.stringify(entry.data));
  data.tool = Object.assign({}, data.tool, { art: Object.assign({}, data.tool && data.tool.art, recipe) });
  saveGameEntry('card', entry.file, data);
  return stats;
}

async function runInferJob(job, entries) {
  try {
    const todo = [];
    for (const entry of entries) {
      if (entry.data.tool && entry.data.tool.art && entry.data.tool.art.prompt)
        job.results.push({ id: entry.id, skipped: true });
      else todo.push(entry);
    }
    job.total = todo.length;
    // LLM passes run in PARALLEL chunks on cloud providers (a local Ollama shares one
    // GPU — parallel requests just thrash it). File WRITES stay strictly serial:
    // concurrent saveGameEntry calls on one file would read-modify-write over each other.
    const width = (getSettings().llmProvider || 'ollama') === 'ollama' ? 1 : 3;
    for (let i = 0; i < todo.length; i += width) {
      const chunk = todo.slice(i, i + width);
      const inferred = await Promise.all(chunk.map(entry =>
        llmInferRecipe(entry, job.adherence).then(recipe => ({ entry, recipe }), e => ({ entry, error: e.message }))));
      for (const { entry, recipe, error } of inferred) {
        if (error) job.results.push({ id: entry.id, error });
        else {
          const stats = persistRecipe(entry, recipe);
          job.results.push({ id: entry.id, prompt: recipe.prompt, ref: recipe.ref && recipe.ref.path, stats });
        }
        job.done++;
      }
    }
    job.status = 'done';
  } catch (e) {
    job.status = 'error';
    job.error = e.message;
  }
}

// ── ✨ effects from words: plain-English description → validated effect JSON ──
// The LLM writes the same dicts Effect.from_dict parses; validateEffects gates every
// attempt and feeds its error message back for a retry. describeEffect (required from
// public/helpers.js — the single English↔JSON source) pairs real game effects with
// their plain-words line as always-current few-shot examples.
const { describeEffect } = require(path.join(PUBLIC, 'helpers.js'));

const EFFECTS_MODEL_DEFAULT = 'qwen3-coder-next:q4_K_M';

// Types whose entries carry a top-level effects array — the example mine.
const FX_OWNER_NOUN = { card: 'this card', relic: 'this relic', status: 'the carrier',
  ability: 'the holder', charm: 'the charmed card', upgrade: 'this upgrade' };

function effectShapeKey(e) {
  const t = e.trigger;
  const trig = t && typeof t === 'object' ? `${t.kind || 'event'}:${t.event || ''}` : String(t || '');
  const tgt = e.targets && typeof e.targets === 'object' ? String(e.targets.kind || 'all') : String(e.targeting_policy || '');
  const kind = e.kind || (e.key ? 'modifier' : e.intercept ? 'interceptor' : e.custom ? 'custom' : 'triggered');
  return [kind, trig, tgt, e.attribute || '', e.status && e.status.id ? 'st' : '', e.key || '', e.custom || ''].join('|');
}

// One valid example per effect SHAPE, same-type entries first — diversity over volume.
function mineEffectExamples(type, cap) {
  const order = [type, ...Object.keys(FX_OWNER_NOUN).filter(t => t !== type && t !== 'upgrade')];
  const seen = new Set(), out = [];
  for (const t of order) {
    if (!FX_OWNER_NOUN[t] || t === 'upgrade') continue;   // upgrade effects live on nested nodes
    for (const entry of listGameEntries(t)) {
      for (const fx of Array.isArray(entry.data.effects) ? entry.data.effects : []) {
        if (out.length >= cap) return out;
        if (validateEffect(fx, 'x')) continue;            // only teach grammar that validates
        const shape = effectShapeKey(fx);
        if (seen.has(shape)) continue;
        seen.add(shape);
        out.push({ english: describeEffect(fx, FX_OWNER_NOUN[t]), json: fx });
      }
    }
  }
  return out;
}

// The effect grammar, spelled for a code model. Status ids are live vocab.
function effectsSystemPrompt() {
  const statusIds = listGameEntries('status').map(e => e.id);
  return [
    "You translate a game designer's plain-English effect description into the game's effect JSON.",
    'Respond with ONLY a JSON array of effect objects — no prose, no markdown fences.',
    '',
    'An effect object takes ONE of these forms:',
    '1. TRIGGERED — reacts to an event:',
    '   {"trigger": <trigger>, "targets": <targets>, plus a payload: "attribute" one of',
    `   ${EFFECT_ATTRS.join('/')} with numeric "amount", and/or "status": {"id": <status id>,`,
    '   "stacks": n?, "duration": rounds?}. Optional "chance": 0..1.}',
    '   attribute "health": negative amount = direct damage, positive = heal.',
    '   attribute "max_health" raises/lowers the unit\'s maximum health (does not heal).',
    '   attribute "damage_taken" deals damage that consumes shield first.',
    `   <trigger> = {"kind":"event","event": one of ${SIMPLE_EVENTS.join('/')}, "of":"self"?, "conditions":[...]?}`,
    `     or {"kind":"dual_event","event": one of ${DUAL_EVENTS.join('/')}, "origin_of":"self"?,`,
    '     "destination_of":"self"?, "origin_conditions":[...]?, "destination_conditions":[...]?}.',
    '   "of"/"origin_of"/"destination_of":"self" = the event must involve the holder itself;',
    '   omit them to react to anyone\'s event. For dual events, origin = the acting unit',
    '   (e.g. attacker), destination = the receiving unit.',
    '2. STANDING — continuous stat change while the effect is active:',
    '   {"trigger": {"kind":"while"}, "targets": {"kind":"self"} or {"kind":"all","conditions":[...]?},',
    '   "attribute": ..., "amount": n, "tracker": {"kind":"stacks"}?}',
    '   tracker "stacks" = the amount applies PER STACK; omit the tracker otherwise.',
    '   Use STANDING for any ongoing/aura wording ("while", "as long as", buffs from a status).',
    `3. MODIFIER — run-wide passive number change: {"kind":"modifier","key": one of ${MODIFIER_KEYS.join('/')},`,
    '   "amount": n, "conditions":[...]?}. Only for run-wide numbers, never for board effects.',
    '4. INTERCEPTOR — rewrites damage before it lands: {"kind":"interceptor","intercept":"damage",',
    '   "channel":"attack"?, "role":"source"|"target", "op":"add"|"mul", "amount": n, "chance":?}',
    `5. CUSTOM code hook: {"kind":"custom","custom": one of ${CUSTOM_HOOKS.join('/')}, "trigger":..., "targets":...}`,
    '',
    '<targets> = {"kind":"self"} | {"kind":"all","conditions":[...]?}',
    '  | {"kind":"auto","criterion":"nearest"|"random","count":n?,"conditions":[...]?}',
    '  | {"kind":"manual"} (the player picks a unit) | {"kind":"manual_slot"} (the player picks a slot)',
    `  | {"kind":"participant","participant":"holder"|"origin"|"destination"} (a trigger participant)`,
    '',
    'A condition object is ONE of:',
    '  {"allegiance":"ally"|"enemy"} — side relative to the effect\'s owner (ally includes the holder)',
    '  {"status": <status id>, "present": false?} — carrying (or not carrying) a status',
    '  {"composition": [<elements/pieces>...], "present": false?} — made of any of these / none of these',
    '  {"card_type":"unit"|"spell"} | {"has_element": true|false}',
    `  {"attribute": one of ${COND_ATTRS.join('/')}, "comparator": one of ${COMPARATORS.join('/')}, "value": n}`,
    '',
    `Vocabulary: elements = ${ELEMENTS.join(', ')}; chess pieces = ${PIECES.join(', ')}.`,
    `Status ids that exist: ${statusIds.join(', ') || '(none yet)'}. Never invent a status id.`,
    'Rules:',
    '- "strength" means the attack attribute.',
    '- Write the SIMPLEST form that says exactly what the text says — no extra conditions,',
    '  chances, triggers or effects the text does not ask for.',
    '- Several distinct effects in the text = several objects in the array. In particular:',
    '  ONE effect object has ONE targets — payloads aimed at different recipients (e.g.',
    '  "poison the target and gain shield" = destination + self) MUST be separate objects,',
    '  each repeating the trigger.',
  ].join('\n');
}

// Strip think blocks / fences, then parse the first JSON array (or lone object) found.
function extractJsonEffects(response) {
  let s = String(response || '')
    .replace(/<think>[\s\S]*?<\/think>/g, '')
    .replace(/```(?:json)?/g, '');
  const start = s.search(/[\[{]/);
  if (start < 0) throw new Error('no JSON in the reply');
  for (let end = s.length; end > start; end--) {
    const cand = s.slice(start, end).trim();
    if (!cand.endsWith(']') && !cand.endsWith('}')) continue;
    try {
      const v = JSON.parse(cand);
      return Array.isArray(v) ? v : [v];
    } catch (e) { /* keep shrinking */ }
  }
  throw new Error('unparseable JSON in the reply');
}

// Generate → validate → feed the error back, up to 3 attempts. Never throws on a
// mere bad answer: the last parseable attempt returns WITH its validation warning,
// so the user fixes a dropdown instead of losing the whole result (the save gate
// still refuses invalid effects).
async function llmEffectsFromText(type, text) {
  const s = getSettings();
  const noun = FX_OWNER_NOUN[type] || 'the holder';
  const examples = mineEffectExamples(type, 10);
  const system = effectsSystemPrompt();
  let user = [
    `Effect holder: a ${TYPES[type].label} ("${noun}").`,
    examples.length ? "Examples (plain words ⇒ JSON) from the game's existing content:" : '',
    ...examples.map(x => `${x.english} ⇒ ${JSON.stringify([x.json])}`),
    `Write the JSON array for: ${text}`,
  ].filter(Boolean).join('\n');
  let best = null, lastErr = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    const out = await llmGenerate({
      model: s.effectsModel || EFFECTS_MODEL_DEFAULT,
      system, prompt: user,
      options: { temperature: attempt === 1 ? 0.2 : 0.5, num_predict: 800 },
    });
    let effects;
    try {
      effects = extractJsonEffects(out.response);
    } catch (e) {
      lastErr = e.message;
      user += `\nYour previous reply was not parseable JSON (${e.message}). Reply with ONLY the JSON array.`;
      continue;
    }
    best = effects;
    const err = validateEffects(effects, 'generated');
    if (!err) return { effects, attempts: attempt };
    lastErr = err;
    user += `\nYou replied: ${JSON.stringify(effects)}\nThe validator rejected it: ${err}\nFix that and reply with ONLY the corrected JSON array.`;
  }
  return { effects: best || [], warning: lastErr, attempts: 3 };
}

// Copies the workspace-generated image to the game's asset path for this entry, backing up
// whatever was there (once). Returns the deployed repo-relative path, or null when the
// entry isn't in the game yet / the type has no art slot (the Save flow retries it).
function deployArtIfPossible(type, id) {
  if (!fs.existsSync(artPath(type, id))) return null;
  const entry = findGameEntry(type, id);
  if (!entry) return null;
  const dir = artDirFor(type, entry.data);
  if (!dir) return null;
  const rel = dir + '/' + artFileFor(type, id);
  const abs = path.join(GAME_ROOT, rel);
  if (fs.existsSync(abs) && !fs.existsSync(editBackupArt(type, id))) {
    ensureDir(path.dirname(editBackupArt(type, id)));
    fs.copyFileSync(abs, editBackupArt(type, id));
  }
  ensureDir(path.dirname(abs));
  fs.copyFileSync(artPath(type, id), abs);
  return rel;
}

async function startArtJob({ type, id, prompt, negative, width, height, steps, guidance, seed, rembg, useRef, refUpload, refGameArt, refMode, denoise, turbo, model }) {
  const t = TYPES[type];
  if (!t) throw new Error('unknown type');
  if (!validId(id)) throw new Error('bad item id');
  const m = MODELS[model || 'flux2'];
  if (!m) throw new Error(`unknown model "${model}"`);
  const w = width || t.artW, h = height || t.artH;
  const s = (seed == null || seed < 0) ? Math.floor(Math.random() * 2 ** 32) : seed;
  const doRembg = rembg == null ? t.rembg : !!rembg;
  const prefix = `tool_${type}_${id}`;
  if (useRef && !m.supportsRef) throw new Error(`${m.label} has no image-reference path — reference input is Flux 2 only`);
  if (turbo && !m.supportsTurbo) throw new Error(`the turbo LoRA is Flux 2 only — ${m.label} has its own speed profile`);
  if (useRef && m.refModes && !m.refModes.some(rm => rm.value === refMode))
    throw new Error(`${m.label} needs a refMode of ${m.refModes.map(rm => rm.value).join(' or ')}`);
  let refName = null;
  if (useRef) {
    let refAbs;
    if (refGameArt) {
      // another item's in-game art, picked from the advanced mode's reference browser
      refAbs = gameArtAbs(refGameArt);
      if (!refAbs) throw new Error('reference game art not found: ' + refGameArt);
    } else if (refUpload) {
      // an external image the user pushed through /api/art/upload-ref
      refAbs = path.join(WORKSPACE, 'refs', safeRefName(refUpload));
      if (!fs.existsSync(refAbs)) throw new Error('uploaded reference image not found — upload it again');
    } else {
      refAbs = currentArtAbs(type, id);
      if (!refAbs) throw new Error('this item has no current art to use as input');
    }
    refName = await uploadRefImage(refAbs, `tool_ref_${type}_${id}.png`);
  }
  const jobId = String(jobSeq++);
  const job = jobs[jobId] = { status: 'running', type, id, seed: s, startedAt: Date.now(), error: null };
  (async () => {
    try {
      const buf = await comfyGenerate({ model: model || 'flux2', prompt, negative, w, h,
        steps, guidance, seed: s, rembg: doRembg, refName, refMode, denoise, turbo, prefix });
      const dest = artPath(type, id);
      ensureDir(path.dirname(dest));
      fs.writeFileSync(dest, buf);
      addToPool(type, id, buf, { source: 'generate', model: model || 'flux2', seed: s, needsRembg: false });
      // The image stays in the tool workspace — deploying into the game's assets is an
      // EXPLICIT act (POST /api/art/deploy, or a new entry's first Save), so the current
      // in-game art survives as reference material until the user commits.
      job.status = 'done';
    } catch (e) {
      job.status = 'error';
      job.error = e.message;
    }
  })();
  return { jobId, seed: s };
}

// Queue ONE ComfyUI generation and await its output image bytes — the primitive the
// single-image art job and the multi-step flow runner both ride. steps/guidance of 0
// (or absent) fall back to the model's defaults.
async function comfyGenerate({ model, prompt, negative, w, h, steps, guidance, seed, rembg, refName, refMode, denoise, turbo, prefix }) {
  const m = MODELS[model];
  const settings = getSettings();
  let lora = null, loraStrength = 1.0;
  if (turbo) {
    if (!settings.turboLora) throw new Error('no turbo LoRA configured — set one in Settings');
    lora = settings.turboLora;
    loraStrength = settings.turboStrength == null ? 1.0 : settings.turboStrength;
  }
  const useSteps = steps || (turbo ? settings.turboSteps || 8 : m.steps);
  const useCfg = guidance || m.guidance;
  let wf;
  if (model === 'krea2') wf = buildKrea2Workflow(prompt, w, h, useSteps, useCfg, seed, prefix, rembg, refName, refMode, denoise);
  else if (model === 'ideogram4') wf = buildIdeogram4Workflow(prompt, w, h, useSteps, useCfg, seed, prefix, rembg);
  else if (model === 'novacartoon') wf = buildNovaCartoonWorkflow(prompt, negative, w, h, useSteps, useCfg, seed, prefix, rembg);
  else wf = buildFluxWorkflow(prompt, w, h, useSteps, useCfg, seed, prefix, rembg, refName, lora, loraStrength);
  const res = await comfyFetch('/prompt', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: wf }),
  });
  if (!res.ok) throw new Error(`ComfyUI queue failed: HTTP ${res.status} ${await res.text()}`);
  const { prompt_id } = await res.json();
  return waitForComfyImage(prompt_id);
}

async function waitForComfyImage(promptId) {
  const startedAt = Date.now();
  for (;;) {
    if (Date.now() - startedAt > 15 * 60 * 1000) throw new Error('timed out after 15 minutes');
    await new Promise(r => setTimeout(r, 2000));
    let hist;
    try {
      const res = await comfyFetch('/history/' + promptId);
      hist = await res.json();
    } catch (e) { continue; }
    const h = hist[promptId];
    if (!h) continue;
    const statusStr = (h.status && h.status.status_str) || '?';
    if (statusStr === 'error')
      throw new Error('ComfyUI error: ' + JSON.stringify((h.status && h.status.messages) || []).slice(0, 2000));
    for (const node of Object.values(h.outputs || {})) {
      for (const img of node.images || []) {
        const qs = new URLSearchParams({ filename: img.filename, subfolder: img.subfolder || '', type: img.type || 'output' });
        const res = await comfyFetch('/view?' + qs.toString());
        if (!res.ok) throw new Error('fetching image failed: view HTTP ' + res.status);
        return Buffer.from(await res.arrayBuffer());
      }
    }
    throw new Error('ComfyUI finished but produced no image (status ' + statusStr + ')');
  }
}

// ── the per-item generation POOL ─────────────────────────────────────────────
// EVERY generated image (single 🎨 runs and every flow candidate) is captured here
// with its metadata, append-only, so nothing is ever lost to an overwrite — the user
// inspects the pool and swaps any entry in as the item's workspace art at will.
// Flow images are stored pre-rembg (chaining needs backgrounds); `needsRembg` marks
// them so pool-use applies removal exactly like a flow pick does.
const POOL_CAP = 60;   // per item; oldest entries pruned past this

function poolDir(type, id) { return path.join(WORKSPACE, 'art', '_pool', type, id); }
function poolManifest(type, id) { return readJson(path.join(poolDir(type, id), 'pool.json'), []); }

function addToPool(type, id, buf, meta) {
  const dir = poolDir(type, id);
  ensureDir(dir);
  let list = poolManifest(type, id);
  const n = (list.length ? Math.max(...list.map(e => e.n)) : 0) + 1;
  const file = `p${String(n).padStart(3, '0')}.png`;
  fs.writeFileSync(path.join(dir, file), buf);
  list.push(Object.assign({ n, file, at: new Date().toISOString() }, meta));
  while (list.length > POOL_CAP) {
    const old = list.shift();
    try { fs.unlinkSync(path.join(dir, old.file)); } catch (e) { /* already gone */ }
  }
  writeJson(path.join(dir, 'pool.json'), list);
}

// ── multi-step generation FLOWS ──────────────────────────────────────────────
// The user's best-results process, automated: e.g. Flux 2 first (prompt adherence),
// then a Krea 2 img2img pass at ~half denoise (visual style). A flow is 1-4 steps,
// each with a model + SAMPLE COUNT — every output of step N feeds step N+1, so
// counts multiply through the tree (1 → 3 → 1 = three finals). All outputs land as
// candidates under workspace/art/_flow/<type>/<id>/ with a manifest; the user picks
// the winner (rembg runs THERE, once — img2img passes need backgrounds intact).
const flowJobs = {};   // jobId -> { id, type, itemId, status, total, done, stepNow, nodes, ... }
let flowSeq = 1;
const FLOW_TOTAL_CAP = 24;

function flowDir(type, id) { return path.join(WORKSPACE, 'art', '_flow', type, id); }
function flowJobForItem(type, id) {
  return Object.values(flowJobs).find(j => j.type === type && j.itemId === id && j.status === 'running') || null;
}

function validateFlowSpec(spec) {
  if (!Array.isArray(spec) || !spec.length || spec.length > 4) return 'a flow needs 1-4 steps';
  let branch = 1, total = 0;
  for (let i = 0; i < spec.length; i++) {
    const st = spec[i] || {};
    const m = MODELS[st.model];
    if (!m) return `step ${i + 1}: unknown model "${st.model}"`;
    const n = parseInt(st.samples, 10);
    if (!(n >= 1 && n <= 8)) return `step ${i + 1}: samples must be 1-8`;
    if (i > 0) {
      if (!m.supportsRef) return `step ${i + 1}: ${m.label} cannot take the previous image as input`;
      // denoise only drives models with an img2img path (Krea 2); Flux 2 chains via ReferenceLatent
      if (m.refModes && !(parseFloat(st.denoise) > 0 && parseFloat(st.denoise) <= 1))
        return `step ${i + 1}: denoise must be between 0 and 1`;
    }
    if (st.turbo && !m.supportsTurbo) return `step ${i + 1}: turbo is Flux 2 only`;
    branch *= n;
    total += branch;
  }
  if (total > FLOW_TOTAL_CAP) return `this flow would generate ${total} images — the cap is ${FLOW_TOTAL_CAP}`;
  return null;
}

async function runFlowJob(job) {
  try {
    const t = TYPES[job.type];
    const dir = flowDir(job.type, job.itemId);
    fs.rmSync(dir, { recursive: true, force: true });   // a new flow replaces the item's last one
    ensureDir(dir);
    // step 1 grows from the ANCHOR image when one is set, from scratch otherwise
    const anchorRef = job.anchorAbs
      ? await uploadRefImage(job.anchorAbs, `tool_flow_anchor_${job.type}_${job.itemId}.png`)
      : null;
    let parents = [null];
    let counter = 0;
    outer:
    for (let si = 0; si < job.spec.length; si++) {
      const st = job.spec[si];
      job.stepNow = si + 1;
      const next = [];
      for (const parent of parents) {
        for (let k = 0; k < parseInt(st.samples, 10); k++) {
          if (job.cancel) break outer;   // stop lands between images (plus a comfy interrupt)
          const seed = Math.floor(Math.random() * 2 ** 32);
          const refName = parent
            ? await uploadRefImage(path.join(dir, parent.file), `tool_flow_${job.type}_${job.itemId}_${parent.n}.png`)
            : anchorRef;
          const buf = await comfyGenerate({
            model: st.model, prompt: job.prompt, negative: job.negative,
            w: t.artW, h: t.artH, steps: parseInt(st.steps, 10) || 0, guidance: parseFloat(st.guidance) || 0,
            seed, rembg: false,   // background removal runs once, on the PICKED image
            refName, refMode: (refName && MODELS[st.model].refModes) ? 'img2img' : undefined,
            denoise: parseFloat(st.denoise) || 0.55, turbo: !!st.turbo,
            prefix: `tool_flow_${job.type}_${job.itemId}`,
          });
          counter++;
          const node = { n: counter, step: si + 1, parent: parent ? parent.n : 0,
            file: `${si + 1}_${String(counter).padStart(2, '0')}.png`,
            seed, model: st.model,
            denoise: (refName && MODELS[st.model].refModes) ? parseFloat(st.denoise) || 0.55 : undefined };
          fs.writeFileSync(path.join(dir, node.file), buf);
          addToPool(job.type, job.itemId, buf, { source: 'flow', model: st.model, seed,
            step: si + 1, needsRembg: !!t.rembg });
          job.nodes.push(node);
          job.done++;
          next.push(node);
        }
      }
      parents = next;
    }
    writeJson(path.join(dir, 'flow.json'),
      { at: new Date().toISOString(), prompt: job.prompt, spec: job.spec,
        anchor: job.anchor || null, nodes: job.nodes });
    job.status = job.cancel ? 'stopped' : 'done';
  } catch (e) {
    // an interrupt aborts the in-flight ComfyUI prompt, which surfaces as an error —
    // when WE cancelled, that's a clean stop, not a failure
    job.status = job.cancel ? 'stopped' : 'error';
    job.error = job.cancel ? null : e.message;
  }
}

// Best-effort: abort whatever ComfyUI is currently generating (its /interrupt endpoint).
function comfyInterrupt() {
  try { comfyFetch('/interrupt', { method: 'POST' }).catch(() => {}); } catch (e) { /* unreachable comfy */ }
}

// Promote one flow candidate to the item's workspace art (rembg once, when the type
// wants it). Shared by the flow-pick endpoint and the Quick Flow batch's auto-pick.
async function applyFlowPick(type, id, file) {
  const abs = path.join(flowDir(type, id), file);
  if (!fs.existsSync(abs)) throw new Error('no such flow image');
  let buf = fs.readFileSync(abs);
  if (TYPES[type].rembg) buf = await rembgImage(abs, `tool_${type}_${id}`);
  ensureDir(path.dirname(artPath(type, id)));
  fs.writeFileSync(artPath(type, id), buf);
  const running = flowJobForItem(type, id);
  const manifest = readJson(path.join(flowDir(type, id), 'flow.json'), null);
  const nodes = running ? running.nodes : ((manifest && manifest.nodes) || []);
  return nodes.find(nd => nd.file === file) || null;
}

// ── Quick Flow BATCH: the appointed flow, run across many cards ──────────────
// The user marks one flow as "Quick Flow" (settings.quickFlow = { steps, anchor });
// a single click then runs it on one card or a whole file. Only cards CARRYING a
// recipe prompt flow (that prompt is the generation prompt); engaging the batch can
// first fill missing recipes (kin inference, chosen adherence). When a card's tree
// completes, ONE image from the LAST step is picked at random and applied as its
// workspace art — pools and per-card flow galleries fill as usual, so a bad random
// pick is one 🗂/⛓ swap away from fixed.
const flowBatchJobs = {};
let flowBatchSeq = 1;
function flowBatchJobForFile(file) {
  return Object.values(flowBatchJobs).find(j => j.file === file && j.status === 'running') || null;
}

// The step-1 anchor for one card under the Quick Flow's anchor POLICY.
function resolveBatchAnchor(entry, policy) {
  if (policy === 'current') return currentArtAbs('card', entry.id);
  if (policy === 'base') {
    const { concept } = inferRelatives(entry);
    const c = concept.find(r => r.bare && r.art) || concept.find(r => r.art);
    return c ? path.join(GAME_ROOT, c.art) : null;
  }
  if (policy === 'recipe') {
    const ref = entry.data.tool && entry.data.tool.art && entry.data.tool.art.ref;
    if (!ref) return null;
    if (ref.source === 'current') return currentArtAbs('card', entry.id);
    if (ref.source === 'game') return gameArtAbs(String(ref.path || ''));
    if (ref.source === 'upload') {
      const abs = path.join(WORKSPACE, 'refs', safeRefName(ref.path));
      return fs.existsSync(abs) ? abs : null;
    }
  }
  return null;
}

async function runFlowBatchJob(job) {
  const hasRecipe = e => !!(e.data.tool && e.data.tool.art && e.data.tool.art.prompt);
  try {
    // phase 1 (opt-in on engage): fill missing recipes first
    if (job.fill) {
      job.phase = 'recipes';
      const missing = job.entries.filter(e => !hasRecipe(e));
      job.total = missing.length;
      for (const entry of missing) {
        if (job.cancel) break;
        job.currentId = entry.id;
        try {
          const recipe = await llmInferRecipe(entry, job.adherence);
          persistRecipe(entry, recipe);
        } catch (e) {
          job.results.push({ id: entry.id, error: 'recipe: ' + e.message });
        }
        job.done++;
      }
    }
    // phase 2: the flows — re-list so freshly filled recipes count
    job.phase = 'flows';
    const entries = listGameEntries('card').filter(e => job.ids.includes(e.id));
    const eligible = entries.filter(hasRecipe);
    for (const e0 of entries.filter(e => !hasRecipe(e)))
      if (!job.results.some(r => r.id === e0.id))
        job.results.push({ id: e0.id, skipped: 'no recipe prompt' });
    job.total = eligible.length;
    job.done = 0;
    const style = (getSettings().artStyle || '').trim();
    let fbranch = 1, ftotal = 0;
    for (const st of job.spec) { fbranch *= parseInt(st.samples, 10); ftotal += fbranch; }
    for (const entry of eligible) {
      if (job.cancel) break;
      job.currentId = entry.id;
      const base = entry.data.tool.art.prompt;
      let anchorAbs = resolveBatchAnchor(entry, job.anchorPolicy);
      if (anchorAbs && !MODELS[job.spec[0].model].supportsRef) anchorAbs = null;
      // a real per-item flow job — galleries, pool capture and reattachment all apply
      const fjob = { id: 'flow' + flowSeq++, type: 'card', itemId: entry.id, status: 'running',
        total: ftotal, done: 0, stepNow: 0, nodes: [], prompt: style ? base + ', ' + style : base,
        negative: '', spec: job.spec, anchorAbs,
        anchor: anchorAbs ? { source: job.anchorPolicy } : null, startedAt: Date.now() };
      flowJobs[fjob.id] = fjob;
      job.currentFjobId = fjob.id;   // the monitor reads live image progress off this
      await runFlowJob(fjob);
      if (fjob.status === 'stopped') {
        job.results.push({ id: entry.id, stopped: true });
        job.done++;
        break;
      }
      if (fjob.status !== 'done') {
        job.results.push({ id: entry.id, error: fjob.error || fjob.status });
      } else {
        const finals = fjob.nodes.filter(n => n.step === job.spec.length);
        const pick = finals[Math.floor(Math.random() * finals.length)];
        await applyFlowPick('card', entry.id, pick.file);
        job.results.push({ id: entry.id, picked: pick.file, seed: pick.seed });
      }
      job.done++;
    }
    job.status = job.cancel ? 'stopped' : 'done';
  } catch (e) {
    job.status = 'error';
    job.error = e.message;
  }
}

// Background-removal-only pass: LoadImage → the same Inspyrenet node the generation
// workflows end with. Runs when a flow pick lands on a type whose art wants rembg.
async function rembgImage(absPng, prefix) {
  const name = await uploadRefImage(absPng, `tool_rembg_${Date.now()}.png`);
  const wf = Object.assign({ 1: { class_type: 'LoadImage', inputs: { image: name } } },
    saveNodes(['1', 0], prefix, true));
  const res = await comfyFetch('/prompt', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: wf }),
  });
  if (!res.ok) throw new Error(`ComfyUI queue failed: HTTP ${res.status} ${await res.text()}`);
  const { prompt_id } = await res.json();
  return waitForComfyImage(prompt_id);
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
        game[t] = listGameEntries(t, true).map(e => ({
          id: e.id,
          name: (e.data && e.data.display_name) || e.id,
          file: e.file,
          edited: !!edits[t + '/' + e.id],
          art: gameArtRel(t, e.id, e.data),
          tool: e.tool || undefined,   // deployed-by-the-tool: browsable, edited via its workspace item
          // composition identity, for the set generator's conflict planning (cards only)
          elements: (e.data && e.data.elements) || undefined,
          chess_pieces: (e.data && e.data.chess_pieces) || undefined,
          // has an authored/inferred art recipe (tool.art prompt) — the ✨ marker
          recipe: (e.data && e.data.tool && e.data.tool.art && e.data.tool.art.prompt) ? true : undefined,
        }));
      }
      return send(res, 200, {
        gameRoot: GAME_ROOT,
        // running batch-inference jobs, so a fresh/reloaded page reattaches its progress UI
        inferJobs: Object.values(inferJobs).filter(j => j.status === 'running')
          .map(j => ({ id: j.id, file: j.file, total: j.total, done: j.done })),
        // running multi-step flows, same reattachment purpose
        flowJobs: Object.values(flowJobs).filter(j => j.status === 'running')
          .map(j => ({ id: j.id, type: j.type, itemId: j.itemId, total: j.total, done: j.done })),
        // running Quick Flow batches
        flowBatchJobs: Object.values(flowBatchJobs).filter(j => j.status === 'running')
          .map(j => ({ id: j.id, file: j.file, phase: j.phase, total: j.total, done: j.done })),
        types: Object.fromEntries(Object.entries(TYPES).map(([k, v]) => [k, {
          label: v.label, dataDir: v.dataDir, artDir: v.artDir, artW: v.artW, artH: v.artH, rembg: v.rembg,
        }])),
        items,
        game,
        vocab: gameVocab(),
        settings: getSettings(),
        artModels: Object.fromEntries(Object.entries(MODELS).map(([k, v]) => [k, {
          label: v.label, steps: v.steps, guidance: v.guidance,
          supportsRef: v.supportsRef, supportsTurbo: v.supportsTurbo, supportsNegative: v.supportsNegative,
          refModes: v.refModes || undefined,
        }])),
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
    if (p === '/api/game/save' && req.method === 'POST') {
      const { type, file, data } = await readBody(req);
      if (!TYPES[type] || !data || !validId(data.id)) return send(res, 400, { error: 'bad request' });
      try {
        return send(res, 200, Object.assign({ ok: true }, saveGameEntry(type, String(file || 'authored.json'), data)));
      } catch (e) { return send(res, 400, { error: e.message }); }
    }
    if (p === '/api/game/delete-entry' && req.method === 'POST') {
      const { type, id } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      try {
        return send(res, 200, Object.assign({ ok: true }, deleteGameEntry(type, id)));
      } catch (e) { return send(res, 400, { error: e.message }); }
    }
    if (p === '/api/game/move-entry' && req.method === 'POST') {
      const { type, id, file } = await readBody(req);
      if (!TYPES[type] || !validId(id) || !file) return send(res, 400, { error: 'bad request' });
      try {
        return send(res, 200, Object.assign({ ok: true }, moveGameEntry(type, id, String(file))));
      } catch (e) { return send(res, 400, { error: e.message }); }
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
        const artRel = artDir + '/' + artFileFor(type, id);
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
      // shared art style: one live prompt fragment + named presets, global across items;
      // the ✨ LLM guidance inputs (concept / how-to-use-references) get preset maps too
      if ('artStyle' in body) s.artStyle = String(body.artStyle || '');
      for (const key of ['stylePresets', 'conceptPresets', 'refHintPresets', 'flowPresets']) {
        if (body[key] && typeof body[key] === 'object') {
          s[key] = {};
          for (const [k, v] of Object.entries(body[key])) s[key][k] = String(v);
        }
      }
      if ('turboLora' in body) s.turboLora = String(body.turboLora || '');
      if ('turboSteps' in body) s.turboSteps = Math.max(1, parseInt(body.turboSteps, 10) || 8);
      if ('turboStrength' in body) s.turboStrength = parseFloat(body.turboStrength) || 1.0;
      if (body.ollamaUrl) s.ollamaUrl = String(body.ollamaUrl);
      if ('llmModel' in body) s.llmModel = String(body.llmModel || '');
      if ('effectsModel' in body) s.effectsModel = String(body.effectsModel || '');
      if ('llmProvider' in body) {
        if (!['ollama', 'claude-code', 'claude', 'openai'].includes(body.llmProvider))
          return send(res, 400, { error: `bad llmProvider "${body.llmProvider}"` });
        s.llmProvider = body.llmProvider;
      }
      if ('claudeModel' in body) s.claudeModel = String(body.claudeModel || '');
      if ('openaiModel' in body) s.openaiModel = String(body.openaiModel || '');
      if ('claudeCodeModel' in body) s.claudeCodeModel = String(body.claudeCodeModel || '');
      if ('claudeCliCmd' in body) s.claudeCliCmd = String(body.claudeCliCmd || 'claude');
      if ('kinAdherence' in body) {
        if (!['concept', 'replicate', 'free'].includes(body.kinAdherence))
          return send(res, 400, { error: `bad kinAdherence "${body.kinAdherence}"` });
        s.kinAdherence = body.kinAdherence;
      }
      if ('kinAnchorMode' in body) {
        if (!['current', 'base'].includes(body.kinAnchorMode))
          return send(res, 400, { error: `bad kinAnchorMode "${body.kinAnchorMode}"` });
        s.kinAnchorMode = body.kinAnchorMode;
      }
      if ('kinThemeMode' in body) {
        if (!['family', 'select'].includes(body.kinThemeMode))
          return send(res, 400, { error: `bad kinThemeMode "${body.kinThemeMode}"` });
        s.kinThemeMode = body.kinThemeMode;
      }
      if ('kinThemeRefs' in body)
        s.kinThemeRefs = Array.isArray(body.kinThemeRefs) ? body.kinThemeRefs.map(String) : [];
      if ('useArtGuides' in body) s.useArtGuides = !!body.useArtGuides;
      if ('kinSteer' in body) s.kinSteer = String(body.kinSteer || '');
      if ('quickFlow' in body) {   // null clears the appointment
        if (body.quickFlow != null) {
          const qfErr = validateFlowSpec(body.quickFlow.steps);
          if (qfErr) return send(res, 400, { error: 'Quick Flow: ' + qfErr });
          if (!['none', 'current', 'base', 'recipe'].includes(body.quickFlow.anchor || 'recipe'))
            return send(res, 400, { error: 'Quick Flow: bad anchor policy' });
        }
        s.quickFlow = body.quickFlow;
      }
      writeJson(SETTINGS_PATH, s);
      return send(res, 200, { ok: true, settings: s });
    }
    // Art guides: composition-keyed authored direction (tool-bound). GET returns the table;
    // POST replaces it wholesale (keys normalized to canonical sorted order).
    if (p === '/api/art-guides' && req.method === 'GET')
      return send(res, 200, { ok: true, guides: getArtGuides() });
    if (p === '/api/art-guides' && req.method === 'POST') {
      const body = await readBody(req);
      const out = { concept: {}, theme: {} };
      for (const axis of ['concept', 'theme']) {
        const src = body[axis] && typeof body[axis] === 'object' ? body[axis] : {};
        for (const [k, v] of Object.entries(src)) {
          const key = compKey(String(k).split('_').filter(Boolean));
          if (!key || !v || typeof v !== 'object') continue;
          out[axis][key] = { label: String(v.label || ''),
            positive: String(v.positive || ''), negative: String(v.negative || '') };
        }
      }
      writeJson(GUIDES_PATH, out);
      return send(res, 200, { ok: true, guides: out });
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
    // ── multi-step flows ──
    if (p === '/api/art/flow' && req.method === 'POST') {
      const { type, id, prompt, negative, steps, anchor } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      if (!prompt || !String(prompt).trim()) return send(res, 400, { error: 'prompt is required' });
      const err = validateFlowSpec(steps);
      if (err) return send(res, 400, { error: err });
      // the step-1 ANCHOR: the concept image the whole tree grows from
      let anchorAbs = null;
      if (anchor && anchor.source && anchor.source !== 'none') {
        if (anchor.source === 'current') anchorAbs = currentArtAbs(type, id);
        else if (anchor.source === 'game') anchorAbs = gameArtAbs(String(anchor.path || ''));
        else if (anchor.source === 'upload') {
          anchorAbs = path.join(WORKSPACE, 'refs', safeRefName(anchor.path));
          if (!fs.existsSync(anchorAbs)) anchorAbs = null;
        }
        if (!anchorAbs) return send(res, 400, { error: 'anchor image not found' });
        if (!MODELS[steps[0].model].supportsRef)
          return send(res, 400, { error: `step 1: ${MODELS[steps[0].model].label} cannot take the anchor image as input` });
      }
      const running = flowJobForItem(type, String(id));
      if (running) return send(res, 200, { ok: true, jobId: running.id, already: true });
      let branch = 1, total = 0;
      for (const st of steps) { branch *= parseInt(st.samples, 10); total += branch; }
      const job = { id: 'flow' + flowSeq++, type, itemId: String(id), status: 'running',
        total, done: 0, stepNow: 0, nodes: [], prompt: String(prompt),
        negative: negative ? String(negative) : '', spec: steps, anchorAbs,
        anchor: anchorAbs ? { source: anchor.source, path: anchor.path } : null, startedAt: Date.now() };
      flowJobs[job.id] = job;
      runFlowJob(job);   // deliberately not awaited — the browser polls
      return send(res, 200, { ok: true, jobId: job.id, total });
    }
    // ── Quick Flow batch ──
    if (p === '/api/art/flow-batch' && req.method === 'POST') {
      const { type, file, ids, fill, adherence } = await readBody(req);
      if (type !== 'card') return send(res, 400, { error: 'quick flows are cards-only for now' });
      const qf = getSettings().quickFlow;
      if (!qf || !Array.isArray(qf.steps) || !qf.steps.length)
        return send(res, 400, { error: 'no Quick Flow appointed yet — open ⛓ Flow… on any card and press ★ Quick Flow' });
      const specErr = validateFlowSpec(qf.steps);
      if (specErr) return send(res, 400, { error: 'the appointed Quick Flow is invalid: ' + specErr });
      let entries;
      if (Array.isArray(ids) && ids.length)
        entries = listGameEntries('card').filter(e => ids.map(String).includes(e.id));
      else if (file) entries = listGameEntries('card').filter(e => e.file === file);
      else return send(res, 400, { error: 'bad request' });
      if (!entries.length) return send(res, 404, { error: 'no matching cards' });
      const jfile = file || entries[0].file;
      const running = flowBatchJobForFile(jfile);
      if (running) return send(res, 200, { ok: true, jobId: running.id, already: true });
      const job = { id: 'fbatch' + flowBatchSeq++, file: jfile, ids: entries.map(e => e.id), entries,
        spec: qf.steps, anchorPolicy: qf.anchor || 'recipe', fill: !!fill, adherence,
        status: 'running', phase: 'starting', total: entries.length, done: 0,
        results: [], cancel: false, currentId: null, startedAt: Date.now() };
      flowBatchJobs[job.id] = job;
      runFlowBatchJob(job);   // deliberately not awaited — the browser polls
      return send(res, 200, { ok: true, jobId: job.id });
    }
    if (p === '/api/art/flow-batch-job') {
      const job = flowBatchJobs[url.searchParams.get('id')];
      if (!job) return send(res, 404, { error: 'no such job' });
      // live image-level progress + landed candidates of the card in flight
      const cur = job.currentFjobId ? flowJobs[job.currentFjobId] : null;
      const currentFlow = (cur && cur.status === 'running' && cur.itemId === job.currentId)
        ? { done: cur.done, total: cur.total, stepNow: cur.stepNow, stepCount: cur.spec.length, nodes: cur.nodes }
        : null;
      return send(res, 200, { status: job.status, phase: job.phase, error: job.error,
        file: job.file, total: job.total, done: job.done, currentId: job.currentId,
        currentFlow, results: job.results, elapsed: Math.round((Date.now() - job.startedAt) / 1000) });
    }
    if (p === '/api/art/flow-batch-stop' && req.method === 'POST') {
      const { id } = await readBody(req);
      const job = flowBatchJobs[id];
      if (!job) return send(res, 404, { error: 'no such job' });
      job.cancel = true;
      const cur = job.currentFjobId ? flowJobs[job.currentFjobId] : null;
      if (cur && cur.status === 'running') cur.cancel = true;
      comfyInterrupt();   // abort the in-flight generation too — cancel means NOW
      return send(res, 200, { ok: true });
    }
    // stop a single (non-batch) flow — the flow modal's Stop button
    if (p === '/api/art/flow-stop' && req.method === 'POST') {
      const { id } = await readBody(req);
      const job = flowJobs[id];
      if (!job) return send(res, 404, { error: 'no such job' });
      job.cancel = true;
      comfyInterrupt();
      return send(res, 200, { ok: true });
    }
    if (p === '/api/art/flow-job') {
      const job = flowJobs[url.searchParams.get('id')];
      if (!job) return send(res, 404, { error: 'no such job' });
      return send(res, 200, { status: job.status, error: job.error, type: job.type, id: job.itemId,
        total: job.total, done: job.done, stepNow: job.stepNow, stepCount: job.spec.length,
        nodes: job.nodes, elapsed: Math.round((Date.now() - job.startedAt) / 1000) });
    }
    // the item's last FINISHED flow (from its on-disk manifest — survives server restarts)
    if (p === '/api/art/flow-result') {
      const type = url.searchParams.get('type'), id = url.searchParams.get('id');
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      return send(res, 200, { ok: true, result: readJson(path.join(flowDir(type, id), 'flow.json'), null) });
    }
    // promote one flow candidate to the item's workspace art (rembg here, when the type wants it)
    if (p === '/api/art/flow-pick' && req.method === 'POST') {
      const { type, id, file } = await readBody(req);
      if (!TYPES[type] || !validId(id) || !/^[0-9]+_[0-9]+\.png$/.test(String(file || '')))
        return send(res, 400, { error: 'bad request' });
      try {
        return send(res, 200, { ok: true, node: await applyFlowPick(type, id, String(file)) });
      } catch (e) {
        return send(res, /no such flow image/.test(e.message) ? 404 : 502, { error: e.message });
      }
    }
    // ── the generation pool ──
    if (p === '/api/art/pool') {
      const type = url.searchParams.get('type'), id = url.searchParams.get('id');
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      return send(res, 200, { ok: true, pool: poolManifest(type, id) });
    }
    if (p === '/api/art/pool-use' && req.method === 'POST') {
      const { type, id, file } = await readBody(req);
      if (!TYPES[type] || !validId(id) || !/^p[0-9]+\.png$/.test(String(file || '')))
        return send(res, 400, { error: 'bad request' });
      const entry = poolManifest(type, id).find(e => e.file === String(file));
      const abs = path.join(poolDir(type, id), String(file));
      if (!entry || !fs.existsSync(abs)) return send(res, 404, { error: 'no such pool image' });
      try {
        let buf = fs.readFileSync(abs);
        if (entry.needsRembg && TYPES[type].rembg) buf = await rembgImage(abs, `tool_${type}_${id}`);
        ensureDir(path.dirname(artPath(type, id)));
        fs.writeFileSync(artPath(type, id), buf);
        return send(res, 200, { ok: true, entry });
      } catch (e) { return send(res, 502, { error: e.message }); }
    }
    if (p === '/api/art/pool-delete' && req.method === 'POST') {
      const { type, id, file } = await readBody(req);
      if (!TYPES[type] || !validId(id) || !/^p[0-9]+\.png$/.test(String(file || '')))
        return send(res, 400, { error: 'bad request' });
      const list = poolManifest(type, id).filter(e => e.file !== String(file));
      try { fs.unlinkSync(path.join(poolDir(type, id), String(file))); } catch (e) { /* gone */ }
      writeJson(path.join(poolDir(type, id), 'pool.json'), list);
      return send(res, 200, { ok: true, count: list.length });
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
    // The explicit "use this in the game" act — generation itself never deploys.
    if (p === '/api/art/deploy' && req.method === 'POST') {
      const { type, id } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      if (!fs.existsSync(artPath(type, id))) return send(res, 400, { error: 'no workspace art for this item' });
      const rel = deployArtIfPossible(type, id);
      if (!rel) return send(res, 400, { error: 'not deployable — the entry is not in the game, or this type has no art slot' });
      return send(res, 200, { ok: true, art: rel });
    }
    // Overwrite the workspace art with client-supplied PNG bytes (the browser does pixel
    // work like horizontal flips on a canvas — the server stays dependency-free).
    if (p === '/api/art/put' && req.method === 'POST') {
      const { type, id, dataBase64 } = await readBody(req);
      if (!TYPES[type] || !validId(id) || !dataBase64) return send(res, 400, { error: 'bad request' });
      ensureDir(path.dirname(artPath(type, id)));
      fs.writeFileSync(artPath(type, id), Buffer.from(dataBase64, 'base64'));
      return send(res, 200, { ok: true });
    }
    // Existing card art ranked by composition affinity, for the advanced mode's browser.
    if (p === '/api/art/references' && req.method === 'POST') {
      const { elements, chess_pieces, excludeId } = await readBody(req);
      return send(res, 200, { refs: rankCardReferences(
        Array.isArray(elements) ? elements.map(String) : [],
        Array.isArray(chess_pieces) ? chess_pieces.map(String) : [],
        excludeId ? String(excludeId) : null) });
    }
    // Ask the local LLM (Ollama) to write an art prompt from the item's summarized data,
    // optionally showing it reference illustrations (refArts: repo-relative assets/ paths).
    if (p === '/api/art/prompt' && req.method === 'POST') {
      const { type, name, summary, example, refArts, concept, refHint, elements, pieces } = await readBody(req);
      if (!TYPES[type] || !name) return send(res, 400, { error: 'bad request' });
      const refImages = [];
      for (const rel of Array.isArray(refArts) ? refArts.slice(0, 4) : []) {
        const abs = gameArtAbs(rel);
        if (!abs) return send(res, 400, { error: 'reference art not found: ' + rel });
        refImages.push(fs.readFileSync(abs).toString('base64'));
      }
      const guides = [...(type === 'card' ? artGuideLines(elements, pieces) : []), ...steerLines()];
      try {
        const prompt = await llmArtPrompt(TYPES[type].label, String(name),
          Array.isArray(summary) ? summary.map(String) : [], example ? String(example) : '', refImages,
          concept ? String(concept) : '', refHint ? String(refHint) : '', guides);
        return send(res, 200, { ok: true, prompt });
      } catch (e) { return send(res, 502, { error: e.message }); }
    }
    // Vision-analyze the item's current art → a prompt that recreates it.
    if (p === '/api/art/prompt-from-art' && req.method === 'POST') {
      const { type, id, concept, refHint } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      const ge = type === 'card' ? findGameEntry('card', id) : null;
      const guides = [...(ge ? artGuideLines(ge.data.elements, ge.data.chess_pieces) : []), ...steerLines()];
      try {
        return send(res, 200, { ok: true, prompt: await llmPromptFromArt(type, id,
          concept ? String(concept) : '', refHint ? String(refHint) : '', guides) });
      } catch (e) {
        return send(res, /no current art/.test(e.message) ? 400 : 502, { error: e.message });
      }
    }
    // ✨ recipe inference for ONE card. Default: returns the recipe, writes nothing
    // (the open editor fills its art draft; the user Saves like any other edit).
    // `persist: true` (the tree's per-item action) writes it onto the entry instead.
    if (p === '/api/art/infer-recipe' && req.method === 'POST') {
      const { type, id, persist, adherence } = await readBody(req);
      if (type !== 'card' || !validId(id)) return send(res, 400, { error: 'recipe inference is cards-only for now' });
      const entry = findGameEntry('card', id);
      if (!entry) return send(res, 404, { error: `no game card with id "${id}"` });
      if (persist && inferJobForFile(entry.file))
        return send(res, 409, { error: `a batch inference is already running over ${entry.file}` });
      try {
        const recipe = await llmInferRecipe(entry, adherence);
        if (persist) {
          const stats = persistRecipe(entry, recipe);
          return send(res, 200, Object.assign({ ok: true, persisted: true, stats }, recipe));
        }
        return send(res, 200, Object.assign({ ok: true }, recipe));
      } catch (e) { return send(res, 502, { error: e.message }); }
    }
    // ✨ recipe inference for a whole FILE — starts a polled server-side JOB (one per
    // file); each inferred recipe is persisted onto its entry as it completes, entries
    // that already carry a recipe prompt are skipped.
    if (p === '/api/art/infer-recipes' && req.method === 'POST') {
      const { type, file, adherence } = await readBody(req);
      if (type !== 'card' || !file) return send(res, 400, { error: 'recipe inference is cards-only for now' });
      const entries = listGameEntries('card').filter(e => e.file === file);
      if (!entries.length) return send(res, 404, { error: 'no card entries in ' + file });
      const running = inferJobForFile(file);
      if (running) return send(res, 200, { ok: true, jobId: running.id, already: true });
      const job = { id: 'infer' + inferSeq++, file, adherence, status: 'running', total: entries.length,
        done: 0, results: [], startedAt: Date.now() };
      inferJobs[job.id] = job;
      runInferJob(job, entries);   // deliberately not awaited — the browser polls
      return send(res, 200, { ok: true, jobId: job.id });
    }
    if (p === '/api/art/infer-job') {
      const job = inferJobs[url.searchParams.get('id')];
      if (!job) return send(res, 404, { error: 'no such job' });
      return send(res, 200, { status: job.status, error: job.error, file: job.file,
        total: job.total, done: job.done, results: job.results,
        elapsed: Math.round((Date.now() - job.startedAt) / 1000) });
    }
    // Plain-English effect description → validated effect JSON (✨ from words).
    if (p === '/api/effects/from-text' && req.method === 'POST') {
      const { type, text } = await readBody(req);
      if (!TYPES[type] || typeof text !== 'string' || !text.trim() || text.length > 2000)
        return send(res, 400, { error: 'bad request' });
      try {
        return send(res, 200, Object.assign({ ok: true }, await llmEffectsFromText(type, text.trim())));
      } catch (e) {
        return send(res, 502, { error: e.message });
      }
    }
    // Stash a user-provided external image in the workspace as generation reference input.
    if (p === '/api/art/upload-ref' && req.method === 'POST') {
      const { name, dataBase64 } = await readBody(req);
      if (!dataBase64) return send(res, 400, { error: 'dataBase64 is required' });
      const safe = safeRefName(name);
      fs.writeFileSync(path.join(WORKSPACE, 'refs', safe), Buffer.from(dataBase64, 'base64'));
      return send(res, 200, { ok: true, name: safe });
    }
    // workspace art preview
    // pool image previews
    if (p.startsWith('/poolart/')) {
      const m = p.match(/^\/poolart\/([a-z]+)\/([a-z0-9_]+)\/(p[0-9]+\.png)$/);
      if (m && TYPES[m[1]] && fs.existsSync(path.join(poolDir(m[1], m[2]), m[3])))
        return send(res, 200, fs.readFileSync(path.join(poolDir(m[1], m[2]), m[3])), 'image/png');
      return send(res, 404, { error: 'no art' });
    }
    // flow candidate previews
    if (p.startsWith('/flowart/')) {
      const m = p.match(/^\/flowart\/([a-z]+)\/([a-z0-9_]+)\/([0-9]+_[0-9]+\.png)$/);
      if (m && TYPES[m[1]] && fs.existsSync(path.join(flowDir(m[1], m[2]), m[3])))
        return send(res, 200, fs.readFileSync(path.join(flowDir(m[1], m[2]), m[3])), 'image/png');
      return send(res, 404, { error: 'no art' });
    }
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

module.exports = { validateItem, buildFluxWorkflow, buildKrea2Workflow, buildIdeogram4Workflow,
  buildNovaCartoonWorkflow, MODELS, TYPES, gameVocab };
