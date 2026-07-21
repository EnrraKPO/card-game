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
  charm:      { label: 'Charm',           dataDir: 'data/charms',     artDir: 'assets/charms',    artW: 512,  artH: 512,  rembg: true  },
  // upgrade trees carry an EMBLEM shown on the Upgrades screen's detail strip
  upgrade:    { label: 'Upgrade Tree',    dataDir: 'data/upgrades',   artDir: 'assets/ui/upgrades', artW: 512, artH: 512, rembg: true },
  encounter:  { label: 'Encounter',      dataDir: 'data/encounters', artDir: null,               artW: 1024, artH: 1024, rembg: false },
  nodeweights:{ label: 'Map Node Weights',dataDir: 'data/map',        artDir: null,               artW: 1024, artH: 1024, rembg: false },
  // sound EVENTS: the game's full SFX library (data/sounds/sounds.json). Audio assets live in
  // assets/sound/ and are produced outside the tool (AI sound gen from each entry's prompt) —
  // no artDir; art generation for this type is reference-only.
  sound:      { label: 'Sound',           dataDir: 'data/sounds',     artDir: null,               artW: 1024, artH: 1024, rembg: false },
  // vfx EVENTS: the game's full visual-effect library (data/vfx/vfx.json), played by id on any
  // Control via the Vfx autoload. Procedural renderer only today; the prompt targets future
  // asset-backed renderers (flipbook sprite sheets).
  vfx:        { label: 'VFX',             dataDir: 'data/vfx',        artDir: null,               artW: 1024, artH: 1024, rembg: false },
  // RENDER FILTERS: parametrized GPU effects (data/render_filters/) applied to a texture-bearing
  // Control, whose look is derived from the SOURCE TEXTURE'S OWN ALPHA — as opposed to the VFX
  // library's procedural behaviors, which draw primitives sized to a target's bounding box and
  // cannot follow a shape. A VFX entry with renderer "filter" names one of these. No artDir: a
  // filter's "art" is its shader.
  render_filter: { label: 'Render Filter', dataDir: 'data/render_filters', artDir: null,          artW: 1024, artH: 1024, rembg: false },
};

// The sound library's category vocabulary — mirrors SoundData.category in the game.
const SOUND_CATEGORIES = ['ui', 'card', 'combat', 'magic', 'resource', 'map', 'economy', 'lab', 'meta', 'ambient', 'music'];
// The VFX library's vocabularies — mirror the game's VFXData/Vfx (keep in sync with
// Vfx.BEHAVIORS / Vfx.SUSTAINED_BEHAVIORS / VFXData.category).
const VFX_CATEGORIES = ['ui', 'card', 'combat', 'status', 'resource', 'map', 'economy', 'lab', 'meta', 'screen'];
const VFX_BEHAVIORS = ['flash', 'pulse', 'pop', 'shake', 'ring', 'sparkle', 'glint', 'glow',
  'float_label', 'burst', 'travel', 'reticle', 'dissolve', 'radiance'];
const VFX_SUSTAINED = ['glow', 'pulse', 'sparkle', 'radiance'];
// 'custom' = a designed effect class registered in-game via Vfx.register_custom (combat looks).
// 'filter' = the look is a RenderFilter (data/render_filters); the VFX entry only owns when it
// runs and how its params animate.
const VFX_RENDERERS = ['procedural', 'custom', 'filter'];   // future: flipbook, scene, ...
// Where a filter draws relative to its source. "behind" is the default and the reason a glow
// doesn't wash out an opaque face — the source occludes the bright core.
const FILTER_LAYERS = ['behind', 'above', 'overlay'];
// Where a filter's silhouette comes from. 'texture' reads the source's alpha; 'rounded_rect'
// describes the shape analytically, for procedural or composed targets with no texture.
const FILTER_SOURCES = ['texture', 'rounded_rect'];

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
ensureDir(path.join(WORKSPACE, 'refs', '.captions'));   // art-derived caption sidecars for canonical assets

// Uploaded reference filenames pass through URLs and the ComfyUI input folder — keep them tame.
function safeRefName(name) { return String(name || 'reference.png').replace(/[^a-zA-Z0-9._-]/g, '_'); }

// ── settings ─────────────────────────────────────────────────────────────────
const SETTINGS_PATH = path.join(WORKSPACE, 'settings.json');
function getSettings() {
  const s = Object.assign({
    comfyUrl: 'http://127.0.0.1:8187', artStyle: '', stylePresets: {},
    audiogenUrl: 'http://127.0.0.1:8188',   // local AudioGen SFX server (tools/audiogen)
    conceptPresets: {}, refHintPresets: {},   // named presets for the ✨ LLM guidance inputs
    flowPresets: {},   // named multi-step generation flows (JSON-encoded step arrays)
    kinAdherence: 'concept',   // ✨ inference default: what carries over from the anchor
    // Anchor source for ✨ inference: 'current' = the card's own art (else its canonical
    // concept) | 'canonical' = always the canonical concept ref | 'custom' = the card's
    // stored recipe reference. (kinThemeMode/kinThemeRefs — the old flat global theme
    // list — is gone: theme now flows ONLY through canonical appointments in art guides.)
    kinAnchorMode: 'current',
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
  // legacy value migration: 'base' (bare-piece hunting) became 'canonical' (appointed ref)
  if (s.kinAnchorMode === 'base') s.kinAnchorMode = 'canonical';
  return s;
}

// ── art guides + canonical references ────────────────────────────────────────
// Tool-bound authored art direction AND canonical reference appointments, keyed by
// COMPOSITION (not by card): `concept` by sorted piece-multiset ("bishop_bishop" →
// Hierophant), `theme` by sorted element-multiset ("air_fire" → Lightning).
//   concept entry = { label, positive, negative, ref,  seeded }
//   theme entry   = { label, positive, negative, refs, seeded }
// A stored ref is ALWAYS {upload: filename} — a FROZEN art asset in workspace/refs,
// immutable and severed from the game. {card: id} exists ONLY as an appoint-time input:
// it means "snapshot this card's CURRENT art into a frozen asset now" (materializeRef),
// and is never persisted. This is the settled rule (a long discussion): a canonical
// reference is an art asset, never a live link into mutable game content — a card's
// authoring prompt must NEVER masquerade as a theme definition (that was the earth_earth
// darkness leak). The art is the single source of truth; the language description the
// LLM reuses is a caption DERIVED FROM the frozen pixels (refCaption), regenerated
// automatically whenever the asset's bytes change.
//   THE RULE (settled with the user): composition identity is atomic — resolution is
// EXACT-multiset match only, never component overlap ("air" may never pollute "air_fire";
// "bishop" may never pollute "bishop_rook"). Canonical refs are MANDATORY for canonical-
// anchored generation: an unappointed slot refuses, it never silently degrades.
// `seeded` marks the ONE-TIME initial setup ran for the key (migrateCanonicalRefs, at
// first startup: concept ← the bare piece card's art; theme ← the composition's
// pawn/knight/queen — snapshotted, not linked). There is NO auto-seeding beyond that:
// a slot cleared or a composition authored later stays unappointed until deliberately
// appointed. Guide text stays opt-in via settings.useArtGuides; canonical refs are not.
const GUIDES_PATH = path.join(WORKSPACE, 'art_guides.json');
function getArtGuides() {
  const g = readJson(GUIDES_PATH, {});
  return { concept: (g && g.concept) || {}, theme: (g && g.theme) || {} };
}
function compKey(arr) { return (Array.isArray(arr) ? arr.slice() : []).sort().join('_'); }

// A stored canonical ref, normalized — or null when it isn't one.
function normalizeCanonicalRef(r) {
  if (!r || typeof r !== 'object') return null;
  if (r.card && validId(r.card)) return { card: String(r.card) };
  if (r.upload) return { upload: safeRefName(r.upload) };
  return null;
}

// Every composition the game's cards actually use (enemy-only cards are OUTSIDE the
// canonical system for now — they neither key compositions nor serve as references).
function allCompositions() {
  const concept = new Set(), theme = new Set();
  for (const e of listGameEntries('card')) {
    if (e.data.enemy_only) continue;
    const pk = compKey(e.data.chess_pieces), ek = compKey(e.data.elements);
    if (pk) concept.add(pk);
    if (ek) theme.add(ek);
  }
  return { concept: [...concept].sort(), theme: [...theme].sort() };
}

// The spec'd default appointments for one composition key, from cards that HAVE art:
// concept ← the bare piece card (exact piece multiset, no elements); theme ← the exact
// element composition's pawn, knight and queen. Missing/artless cards contribute nothing.
function seedDefaultsFor(axis, key) {
  const entries = listGameEntries('card').filter(e => !e.data.enemy_only);
  if (axis === 'concept') {
    const bare = entries.find(e => compKey(e.data.chess_pieces) === key
      && !(e.data.elements || []).length && gameArtRel('card', e.id, e.data));
    return bare ? { ref: { card: bare.id } } : { ref: null };
  }
  const refs = [];
  for (const piece of ['pawn', 'knight', 'queen']) {
    const hit = entries.find(e => compKey(e.data.elements) === key
      && compKey(e.data.chess_pieces) === piece && gameArtRel('card', e.id, e.data));
    if (hit) refs.push({ card: hit.id });
  }
  return { refs };
}

// Snapshot a card's CURRENT art into a frozen workspace asset, returning {upload:name}.
// This is how a {card} appointment is materialized: the bytes are copied once and the
// link to the (mutable) game card is severed — nothing reads that card again. An already
// -frozen {upload} ref passes through untouched. Null when the source has no usable art.
function materializeRef(ref) {
  const r = normalizeCanonicalRef(ref);
  if (!r) return null;
  if (r.upload) return r;   // already a frozen asset
  const e = findGameEntry('card', r.card);
  if (!e || e.data.enemy_only) return null;
  const art = gameArtRel('card', e.id, e.data);
  const src = art && path.join(GAME_ROOT, art);
  if (!src || !fs.existsSync(src)) return null;
  const name = safeRefName(`snap_${e.id}.png`);
  fs.copyFileSync(src, path.join(WORKSPACE, 'refs', name));
  return { upload: name };
}

// The default appointments for a key, materialized to frozen assets (used by initial
// setup and the per-key re-seed endpoint). Same shape the guide entry stores.
function materializeDefaults(axis, key) {
  const def = seedDefaultsFor(axis, key);
  if (axis === 'concept') return { ref: def.ref ? materializeRef(def.ref) : null };
  return { refs: (def.refs || []).map(materializeRef).filter(Boolean) };
}

// ONE-TIME initial setup: snapshot the spec'd default art into frozen assets for every
// never-seeded composition, and convert any lingering {card} appointment to a frozen
// snapshot. Guarded by a sentinel so it runs exactly once — there is NO auto-seeding
// beyond this: later-authored compositions stay unappointed until deliberately appointed.
const CANON_MIGRATED = path.join(WORKSPACE, '.canon_refs_migrated');
function migrateCanonicalRefs() {
  if (fs.existsSync(CANON_MIGRATED)) return;
  const g = getArtGuides();
  const comps = allCompositions();
  for (const [axis, keys] of [['concept', comps.concept], ['theme', comps.theme]]) {
    for (const key of keys) {
      const entry = g[axis][key] || (g[axis][key] = { label: '', positive: '', negative: '' });
      if (!entry.seeded) {
        Object.assign(entry, materializeDefaults(axis, key));
        entry.seeded = true;
      } else if (axis === 'concept') {   // convert a lingering {card} link to a snapshot
        if (entry.ref && entry.ref.card) entry.ref = materializeRef(entry.ref);
      } else {
        entry.refs = (Array.isArray(entry.refs) ? entry.refs : [])
          .map(r => (r && r.card) ? materializeRef(r) : normalizeCanonicalRef(r)).filter(Boolean);
      }
    }
  }
  writeJson(GUIDES_PATH, g);
  fs.writeFileSync(CANON_MIGRATED, new Date().toISOString());
}

// Resolve one stored ref to a FROZEN asset: { kind:'upload', name, abs } or null. Only
// {upload} resolves — a {card} ref is not canonical (it must be materialized at appoint
// time); an unmaterialized one reads as unappointed, which fails loud rather than
// silently reaching back into mutable game content.
function resolveCanonicalRef(ref) {
  const r = normalizeCanonicalRef(ref);
  if (!r || !r.upload) return null;
  const abs = path.join(WORKSPACE, 'refs', r.upload);
  return fs.existsSync(abs) ? { kind: 'upload', name: r.upload, abs } : null;
}

// ── canonical asset captions ─────────────────────────────────────────────────
// A canonical reference's language description is DERIVED FROM its frozen art, cached in
// a sidecar and regenerated lazily whenever the asset's bytes change (sha mismatch) or
// no caption exists yet. The art is the sole source — a caption never carries any card's
// authoring prompt. This gives inference the cheap-and-exact TEXT it wants without the
// contamination of reusing a mutable input prompt.
function captionSidecarPath(name) {
  return path.join(WORKSPACE, 'refs', '.captions', safeRefName(name) + '.json');
}
async function captionAsset(abs) {
  const out = await llmGenerate({
    system: LLM_MATCH_SYSTEM_PROMPT,
    prompt: 'Write the prompt that recreates this illustration.',
    images: [fs.readFileSync(abs).toString('base64')],
    options: { temperature: 0.4, num_predict: 200 },
  });
  return cleanLlmPrompt(out);
}
async function refCaption(name, abs) {
  const sha = fileHash(abs);
  const scPath = captionSidecarPath(name);
  const cur = readJson(scPath, null);
  if (cur && cur.sha === sha && cur.description) return cur.description;
  const description = await captionAsset(abs);
  writeJson(scPath, { sha, description, provider: getSettings().llmProvider, at: new Date().toISOString() });
  return description;
}

// The MANDATORY canonical pools for a card. Exact-composition lookup only; a missing or
// unresolvable appointment throws (the caller surfaces the message) — never a fallback.
function canonicalConceptFor(pieces) {
  const key = compKey(pieces);
  if (!key) return null;   // no pieces (a pure spell) — concept simply doesn't apply
  const entry = getArtGuides().concept[key];
  const resolved = entry && entry.ref ? resolveCanonicalRef(entry.ref) : null;
  if (!resolved) throw new Error(`no canonical concept appointed for "${key}" — appoint it in ✨ Art guides`);
  return resolved;
}
function canonicalThemeFor(elements) {
  const key = compKey(elements);
  if (!key) return [];   // no elements (a bare piece card) — theme doesn't apply
  const entry = getArtGuides().theme[key];
  const resolved = (entry && Array.isArray(entry.refs) ? entry.refs : [])
    .map(resolveCanonicalRef).filter(Boolean);
  if (!resolved.length) throw new Error(`no canonical theme appointed for "${key}" — appoint it in ✨ Art guides`);
  return resolved;
}

// ── offer rarity ─────────────────────────────────────────────────────────────
// Global tuning for how likely each card is to be OFFERED (reward/shop/stage-clear).
// Lives in the game's own data/offer_rarity.json (read by CardData.offer_weight). Mirror
// of the game's OFFER_RARITY_DEFAULT so the tool round-trips the same shape / fallbacks.
const OFFER_RARITY_PATH = path.join(GAME_ROOT, 'data/offer_rarity.json');
const OFFER_RARITY_DEFAULT = {
  piece_rarity: { pawn: 4, knight: 5, bishop: 5, rook: 5, queen: 20, king: 5 },
  element_rarity: 10,
  count_multiplier: { '1': 1, '2': 2, '3': 3, '4': 4 },
};
function getOfferRarity() {
  const d = readJson(OFFER_RARITY_PATH, {}) || {};
  return {
    piece_rarity: Object.assign({}, OFFER_RARITY_DEFAULT.piece_rarity,
      (d.piece_rarity && typeof d.piece_rarity === 'object') ? d.piece_rarity : {}),
    element_rarity: Number.isFinite(d.element_rarity) ? d.element_rarity : OFFER_RARITY_DEFAULT.element_rarity,
    count_multiplier: Object.assign({}, OFFER_RARITY_DEFAULT.count_multiplier,
      (d.count_multiplier && typeof d.count_multiplier === 'object') ? d.count_multiplier : {}),
  };
}
// The actual offerable pool, derived from the game's card files exactly as the game filters it
// (random_non_kings: not is_king, not enemy_only, and skipping tool-disabled entries). Each entry
// carries its element count + piece list so the tool can compute the live distribution client-side.
function offerRarityPool() {
  const dir = path.join(GAME_ROOT, 'data/cards');
  const out = [];
  let files = [];
  try { files = fs.readdirSync(dir).filter(f => f.endsWith('.json')); } catch (e) { return out; }
  for (const f of files) {
    const data = readJson(path.join(dir, f), null);
    const entries = Array.isArray(data) ? data : (data ? [data] : []);
    for (const c of entries) {
      if (!c || typeof c !== 'object' || !c.id) continue;
      if (c.enabled === false || c.is_king || c.enemy_only) continue;
      const p = Array.isArray(c.chess_pieces) ? c.chess_pieces.slice() : [];
      const e = Array.isArray(c.elements) ? c.elements.length : 0;
      if (e === 0 && p.length === 0) continue;   // no composition to weight
      out.push({ id: c.id, e, p });
    }
  }
  return out;
}

// ── combat tuning (dodge + crit) ─────────────────────────────────────────────
// Global combat balance knobs. Lives in the game's own data/combat_tuning.json (read by
// Resolver._dodge_config / _crit_config). Mirrors of the game's DODGE_DEFAULT / CRIT_DEFAULT so
// the tool round-trips the same shape / fallbacks. All rates are PERCENTAGES. Dodge chance =
// fixed + per_speed×tgt_speed + per_speed_diff×max(0, tgt−atk speed), capped at max. Crit is
// the offensive mirror — the ATTACKER's speed drives it — plus the damage multiplier pair
// (multiplier = the crit damage factor, multiplier_max its hard ceiling).
const COMBAT_TUNING_PATH = path.join(GAME_ROOT, 'data/combat_tuning.json');
const AUDIO_TUNING_PATH = path.join(GAME_ROOT, 'data/audio.json');
const DODGE_DEFAULT = { fixed_pct: 0, per_speed_pct: 1, per_speed_diff_pct: 4, max_pct: 75 };
const CRIT_DEFAULT = { fixed_pct: 5, per_speed_pct: 1, per_speed_diff_pct: 0, max_pct: 75,
  multiplier: 2.0, multiplier_max: 5.0 };
function mergeTuning(authored, defaults) {
  const src = (authored && typeof authored === 'object') ? authored : {};
  const num = (v, fb) => Number.isFinite(v) ? v : fb;
  const out = {};
  for (const k of Object.keys(defaults)) out[k] = num(src[k], defaults[k]);
  return out;
}
// ── debug mode (local launch config) ─────────────────────────────────────────
// The per-machine debug.json at the game root (read by the game's DebugConfig; git-ignored,
// never shipped). The game treats an ABSENT file as debug ON — the toggle materializes the
// file on first write, then flips it in place.
const DEBUG_MODE_PATH = path.join(GAME_ROOT, 'debug.json');
function getDebugMode() {
  const d = readJson(DEBUG_MODE_PATH, null);
  return { enabled: !(d && d.enabled === false), exists: fs.existsSync(DEBUG_MODE_PATH) };
}

// ── economy (starting resources) ─────────────────────────────────────────────
// The data-driven starting economy (scripts/economy_config.gd): what a fresh profile/run
// begins with. Two bags — `initial` (the shipping economy) and `debug` (dev overrides:
// while enabled it REPLACES initial; gold -1 = no override, keep gold.initial). Lives in
// the game's own data/economy.json. Mirror of the game's defaults (the old TEMP dev seed
// as the debug bag) so the tool round-trips the same shape / fallbacks.
const ECONOMY_PATH = path.join(GAME_ROOT, 'data/economy.json');
const MAT_ELEMENTS = ['fire', 'water', 'air', 'earth', 'darkness', 'light'];
const MAT_PIECES = ['pawn', 'knight', 'bishop', 'rook', 'queen', 'king'];
const MATERIAL_IDS = [
  ...MAT_ELEMENTS,                          // essences (bare element id)
  ...MAT_ELEMENTS.map(e => e + '_stone'),   // stones
  ...MAT_PIECES.map(p => p + '_piece'),     // chess-piece tokens
  'magic_mineral',
];
const ECONOMY_DEFAULT = {
  initial: { materials: {}, upgrade_points: 0 },
  debug: {
    enabled: true, gold: -1, magic_mineral: -1,
    materials: Object.assign({ king_piece: 21 },
      ...MAT_PIECES.filter(p => p !== 'king').map(p => ({ [p + '_piece']: 10 })),
      ...MAT_ELEMENTS.map(e => ({ [e + '_stone']: 10 }))),
    upgrade_points: 12,
  },
};
// Sanitizes one bag against its default: materials taken wholesale when authored (known
// ids, positive integer counts), scalars replaced when well-typed.
function economyBag(src, def, isDebug) {
  const s = (src && typeof src === 'object') ? src : {};
  const out = { materials: {}, upgrade_points: def.upgrade_points };
  const mats = (s.materials && typeof s.materials === 'object') ? s.materials : def.materials;
  for (const id of MATERIAL_IDS) {
    const v = Number(mats[id]);
    if (Number.isFinite(v) && v > 0) out.materials[id] = Math.round(v);
  }
  if (Number.isFinite(s.upgrade_points) && s.upgrade_points >= 0) out.upgrade_points = Math.round(s.upgrade_points);
  if (isDebug) {
    out.enabled = typeof s.enabled === 'boolean' ? s.enabled : def.enabled;
    out.gold = (Number.isFinite(s.gold) && s.gold >= 0) ? Math.round(s.gold) : -1;
    out.magic_mineral = (Number.isFinite(s.magic_mineral) && s.magic_mineral >= 0)
      ? Math.round(s.magic_mineral) : -1;
  }
  return out;
}
function getEconomy() {
  const d = readJson(ECONOMY_PATH, {}) || {};
  return {
    initial: economyBag(d.initial, ECONOMY_DEFAULT.initial, false),
    debug: economyBag(d.debug, ECONOMY_DEFAULT.debug, true),
  };
}

// ── game attributes ──────────────────────────────────────────────────────────
// The global run/match numbers (GameAttributes.DEFAULTS in scripts/game_attributes.gd).
// Lives in the game's own data/game_attributes.json, read by GameAttributes.default_value
// as overrides on the code defaults — an absent file means pure defaults. Mirror of the
// game's DEFAULTS so the tool round-trips the same shape / fallbacks.
const GAME_ATTRS_PATH = path.join(GAME_ROOT, 'data/game_attributes.json');
const GAME_ATTRS_DEFAULT = {
  'mana.initial': 1, 'mana.max': 10, 'mana.per_turn': 0, 'hand.size.initial': 3,
  'draw.per_turn': 1, 'gold.initial': 100, 'magic_mineral.initial': 5,
  'king.max_health': 0, 'relic.capacity': 10,
  'reward.essence': 0, 'reward.king_piece_chance': 0.0,
  'reward.gold.combat': 0, 'reward.gold.elite': 0, 'reward.gold.boss': 0,
  'reward.magic_mineral.combat': 2, 'reward.magic_mineral.elite': 3, 'reward.magic_mineral.boss': 5,
  'forge.cost.per_piece': 2, 'forge.cost.per_element': 1,
  'forge.cost.element_only': 0, 'forge.cost.piece_op': 1,
  'shop.magic_mineral.price': 25,
  // Input feel (touch gesture windows) — see GameAttributes' "ux." block.
  'ux.hold.duration': 0.4, 'ux.hold.tolerance': 44,
};
function getGameAttrs() {
  const d = readJson(GAME_ATTRS_PATH, {}) || {};
  const out = {};
  for (const k of Object.keys(GAME_ATTRS_DEFAULT))
    out[k] = Number.isFinite(d[k]) ? d[k] : GAME_ATTRS_DEFAULT[k];
  return out;
}

function getCombatTuning() {
  const d = readJson(COMBAT_TUNING_PATH, {}) || {};
  return {
    dodge: mergeTuning(d.dodge, DODGE_DEFAULT),
    crit: mergeTuning(d.crit, CRIT_DEFAULT),
  };
}

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
const DUAL_EVENTS = ['attack','struck','kill','dodge','crit'];
const RELATIONS = ['self','ally','enemy'];   // legacy spelling; ally/enemy map to allegiance in-game
const ALLEGIANCES = ['ally','enemy'];        // side vs the effect's OWNER — the native predicate form
const PARTICIPANT_GATES = ['self','any'];    // trigger "of" gates (identity is structural, not a condition)
const TRACKER_KINDS = ['container','stacks'];
// The native targeting schema (see scripts/triggers/target_resolver.gd).
const TARGET_KINDS = ['self','all','auto','manual','manual_slot','participant','side'];
const CRITERIA = ['nearest','random'];
const PARTICIPANTS = ['holder','origin','destination'];
const SIDE_SELECTORS = ['own','opponent'];   // the side kind's "of" (relative to the holder)
const POLICIES = ['self','single_nearest','single_random','all_enemies','all_allies','all','manual','attack_target','subject','attacker','manual_slot'];
const SUBJECTS = ['self','ally','enemy','any'];
const COMPARATORS = ['gt','gte','lt','lte','eq','neq'];
const MODIFIER_KEYS = ['unit.attack','unit.health','unit.speed','card.cost',
  'mana.initial','mana.max','mana.per_turn','hand.size.initial','draw.per_turn',
  'gold.initial','magic_mineral.initial','king.max_health','relic.capacity',
  'reward.essence','reward.king_piece_chance',
  'reward.gold.combat','reward.gold.elite','reward.gold.boss',
  'reward.magic_mineral.combat','reward.magic_mineral.elite','reward.magic_mineral.boss',
  'forge.cost.per_piece','forge.cost.per_element','forge.cost.element_only','forge.cost.piece_op',
  'shop.magic_mineral.price'];
const CUSTOM_HOOKS = ['rallying_cry','deliver_material'];
const EFFECT_ATTRS = ['health','max_health','damage_taken','attack','speed','shield','cost',
  'dodge_bonus','crit_chance_bonus','crit_multiplier_bonus','strikes'];
// Side stats: only valid with targets {"kind":"side"} and vice versa (mirrors
// Effect._validate_side_targets — see EFFECT_SYSTEM_DESIGN.md §10).
const SIDE_ATTRS = ['draw','discard','mana','max_mana'];
// The stats a pending mutation can carry — the interceptor match vocabulary (mirrors
// StatMutation + the Resolver's split: "damage" is a hit's pre-split total; its shares
// then pass as "shield_pool" / "health" on the hit's channel).
const INTERCEPT_STATS = ['damage','health','shield_pool','status',
  'attack','speed','cost','max_health','shield', ...SIDE_ATTRS];
// The attributes the game's read-time fold serves — the ONLY legal standing (while)
// targets (mirrors Effect.FOLDABLE_ATTRS/FOLDABLE_MAP: pool-named attributes fold as
// their base — "health" means max_health, "shield" the shield base the pool follows).
const FOLDABLE_MAP = { health: 'max_health', shield: 'max_shield' };
const FOLDABLE_ATTRS = ['max_health', 'attack', 'speed', 'cost', 'max_shield',
  'dodge_bonus', 'crit_chance_bonus', 'crit_multiplier_bonus', 'strikes'];
const COND_ATTRS = ['health','attack','speed','cost','piece_count','element_count'];
const ELEMENTS = ['fire','water','air','earth','darkness','light'];
const PIECES = ['pawn','knight','bishop','rook','queen','king'];

function validateConditionList(list, where, allowMutation) {
  for (let i = 0; i < (list || []).length; i++) {
    const c = list[i];
    if (c.status) continue;
    if (c.mutation) {
      // Mutation-form conditions predicate over a PENDING StatMutation — only the
      // interceptor match evaluates them (mirrors Effect.from_dict's fail-loud rule).
      if (!allowMutation) return `${where} condition ${i + 1}: mutation-form conditions are only valid on interceptors`;
      if (c.mutation !== 'amount') return `${where} condition ${i + 1}: bad mutation attribute "${c.mutation}"`;
      if (!COMPARATORS.includes(c.comparator)) return `${where} condition ${i + 1}: bad comparator`;
      continue;
    }
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
    // The `cause` gate is unique to `kill` — a free-form provenance match (a status id like
    // "poison", or the kind "attack"/"effect"); mirrors TriggerResolver.Dual.cause.
    if (t.cause != null) {
      if (t.event !== 'kill') return `${where}: "cause" gates only the kill event`;
      if (typeof t.cause !== 'string' || !t.cause) return `${where}: "cause" must be a non-empty string`;
    }
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
  if (kind === 'side') {
    if (!SIDE_SELECTORS.includes(String(t.of || 'own'))) return `${where}: bad side selector "${t.of}" (own/opponent)`;
    if ((t.conditions || []).length) return `${where}: side targets take no conditions (players have nothing to predicate on)`;
  }
  return validateConditionList(t.conditions, `${where} targets`);
}

function validateEffect(e, where) {
  if (!e || typeof e !== 'object') return `${where}: effect must be an object`;
  const kind = e.kind || (e.key ? 'modifier' : e.intercept ? 'interceptor' : e.custom ? 'custom' : 'triggered');
  // Composition grants live on standing triggered effects only (mirrors Effect._validate_grants).
  if (e.grants != null && kind !== 'triggered')
    return `${where}: grants is only valid on a standing (while) effect`;
  if (kind === 'modifier') {
    if (!MODIFIER_KEYS.includes(e.key)) return `${where}: unknown modifier key "${e.key}"`;
    if (typeof e.amount !== 'number') return `${where}: modifier needs a numeric amount`;
  } else if (kind === 'interceptor') {
    if (!e.intercept) return `${where}: interceptor needs an "intercept" stat (${INTERCEPT_STATS.join('/')})`;
    if (!INTERCEPT_STATS.includes(e.intercept))
      return `${where}: unknown intercept stat "${e.intercept}" — a mutation only ever carries one of ${INTERCEPT_STATS.join('/')}`;
    if (e.role && !['source','target'].includes(e.role)) return `${where}: bad role`;
    // Native relational gate: which mutation participant is scrutinised + its relation.
    if (e.of != null) {
      if (typeof e.of !== 'object') return `${where}: interceptor "of" must be an object`;
      if (e.of.participant && !['source','target'].includes(e.of.participant)) return `${where}: bad intercept participant "${e.of.participant}"`;
      if (e.of.relation && !['self','ally','enemy','any'].includes(e.of.relation)) return `${where}: bad intercept relation "${e.of.relation}"`;
    }
    return validateConditionList(e.conditions, where, true);
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
    if (e.attribute && !EFFECT_ATTRS.includes(e.attribute) && !SIDE_ATTRS.includes(e.attribute)) return `${where}: bad attribute "${e.attribute}"`;
    // Side-stat/side-target pairing, fail-loud both ways (Effect._validate_side_targets).
    const sideTargeted = e.targets && typeof e.targets === 'object' && String(e.targets.kind || '') === 'side';
    if (SIDE_ATTRS.includes(e.attribute) && !sideTargeted)
      return `${where}: side stat "${e.attribute}" requires targets {"kind": "side"}`;
    if (sideTargeted && !SIDE_ATTRS.includes(e.attribute))
      return `${where}: side-targeted attribute must be one of ${SIDE_ATTRS.join('/')}`;
    if (sideTargeted && e.status && e.status.id)
      return `${where}: a side-targeted effect cannot apply a status`;
    // The "spawn units" payload (mirrors Effect.spawn_id/spawn_count): triggered-only,
    // never standing, never side-targeted; card-id existence is the game loader's check.
    if (e.spawn != null) {
      if (typeof e.spawn !== 'object' || !e.spawn.id)
        return `${where}: spawn must be an object naming a card id ({"id": ..., "count": n})`;
      if (e.spawn.count != null && (!Number.isInteger(e.spawn.count) || e.spawn.count < 1))
        return `${where}: spawn count must be a positive integer`;
      if (sideTargeted) return `${where}: a side-targeted effect cannot spawn units`;
    }
    const standing = e.trigger && typeof e.trigger === 'object' && e.trigger.kind === 'while';
    const hasGrants = Array.isArray(e.grants) && e.grants.length > 0;
    if (standing) {
      // Mirrors the game's fail-loud rules (Effect._validate_standing): a standing effect
      // is a continuous stat fold — nothing else is meaningful on it, and only attributes
      // the read-time fold actually serves are legal (membership, not mere presence —
      // anything else would be computed and read by nobody). A composition GRANT is the
      // one other standing payload: its component set replaces the attribute.
      if (!e.attribute && !hasGrants)
        return `${where}: a standing (while) effect needs an attribute to fold (or a grants set)`;
      if (e.attribute && !FOLDABLE_ATTRS.includes(FOLDABLE_MAP[e.attribute] || e.attribute))
        return `${where}: attribute "${e.attribute}" cannot be standing — only `
          + `health/shield/${FOLDABLE_ATTRS.join('/')} fold at read time`;
      if (e.status && e.status.id) return `${where}: a standing (while) effect cannot apply a status`;
      if (e.spawn && e.spawn.id) return `${where}: a standing (while) effect cannot spawn units`;
      const tk = e.targets && typeof e.targets === 'object' ? String(e.targets.kind || 'all') : 'all';
      if (!['self','all'].includes(tk)) return `${where}: standing targets must be "self" or "all"`;
    }
    if (e.grants != null) {
      // Mirrors Effect._validate_grants: standing-only, union-only, canonical ids, and
      // NO negative composition predicates (Layer-1 monotonicity — grants only ever ADD;
      // the game's fixed point is provably convergent only while this holds).
      if (!Array.isArray(e.grants) || !e.grants.length)
        return `${where}: grants must be a non-empty array of component ids`;
      for (const g of e.grants)
        if (!ELEMENTS.includes(g) && !PIECES.includes(g))
          return `${where}: "${g}" in grants is not an element or chess piece`;
      if (!standing) return `${where}: grants requires a standing (while) trigger`;
      if (e.attribute || (e.status && e.status.id))
        return `${where}: grants is exclusive with the attribute/status payloads`;
      const grantConds = [...(e.conditions || []),
        ...((e.targets && typeof e.targets === 'object' && e.targets.conditions) || [])];
      for (const c of grantConds) {
        if (c && c.composition && c.present === false)
          return `${where}: a composition grant cannot carry a negative composition condition (grants only ever ADD)`;
        if (c && c.has_element === false)
          return `${where}: a composition grant cannot carry has_element:false (grants only ever ADD)`;
      }
    }
    const hasPayload = e.attribute || (e.status && e.status.id) || hasGrants || (e.spawn && e.spawn.id);
    if (!hasPayload) return `${where}: effect does nothing — set an attribute change, a status to apply, or units to spawn`;
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
    case 'sound': {
      if (!d.display_name) return 'missing display_name';
      if (!SOUND_CATEGORIES.includes(d.category)) return `category must be one of: ${SOUND_CATEGORIES.join(', ')}`;
      if (!d.concept) return 'missing concept — record what this moment is and how it should feel';
      if (!d.prompt) return 'missing prompt — the AI sound-generation text';
      if (d.file && !/^[a-zA-Z0-9._-]+\.(mp3|ogg|wav)$/.test(d.file)) return 'file must be a bare .mp3/.ogg/.wav filename inside assets/sound/';
      if (d.dir != null && !/^[a-zA-Z0-9_-]+(\/[a-zA-Z0-9_-]+)*$/.test(d.dir)) return 'dir must be a folder path inside assets/ (e.g. music/combat)';
      if (d.fade != null && (typeof d.fade !== 'number' || d.fade <= 0)) return 'fade must be a positive number of seconds';
      if (d.trim != null && (typeof d.trim !== 'number' || d.trim < 0)) return 'trim must be a non-negative number of seconds';
      if (d.volume_db != null && typeof d.volume_db !== 'number') return 'volume_db must be a number';
      return null;
    }
    case 'vfx': {
      if (!d.display_name) return 'missing display_name';
      if (!VFX_CATEGORIES.includes(d.category)) return `category must be one of: ${VFX_CATEGORIES.join(', ')}`;
      if (d.renderer && !VFX_RENDERERS.includes(d.renderer)) return `renderer must be one of: ${VFX_RENDERERS.join(', ')}`;
      if (!VFX_BEHAVIORS.includes(d.behavior)) return `behavior must be one of: ${VFX_BEHAVIORS.join(', ')}`;
      if (d.sustained && !VFX_SUSTAINED.includes(d.behavior)) return `sustained needs a sustain-capable behavior (${VFX_SUSTAINED.join(', ')})`;
      if (!d.concept) return 'missing concept — what this moment means';
      if (!d.explanation) return 'missing explanation — what the effect looks like';
      if (!d.prompt) return 'missing prompt — the AI generation text for a future asset look';
      if (d.sfx != null) {
        if (typeof d.sfx !== 'string') return 'sfx must be a sound id string';
        if (d.sfx && !scanGameJson('data/sounds').some(({ entry: s }) => s.id === d.sfx))
          return `sfx "${d.sfx}" is not an installed sound id (data/sounds)`;
      }
      if (d.params != null) {
        if (typeof d.params !== 'object' || Array.isArray(d.params)) return 'params must be an object';
        for (const k of ['color', 'color2'])
          if (d.params[k] != null && !/^[0-9a-fA-F]{6}$/.test(d.params[k])) return `params.${k} must be a 6-digit hex colour`;
        for (const k of ['scale', 'duration', 'intensity'])
          if (d.params[k] != null && typeof d.params[k] !== 'number') return `params.${k} must be a number`;
      }
      return null;
    }
    case 'render_filter': {
      if (!d.display_name) return 'missing display_name';
      if (typeof d.shader !== 'string' || !/^res:\/\/.*\.gdshader$/.test(d.shader))
        return 'shader must be a res:// path to a .gdshader file';
      if (!fs.existsSync(path.join(GAME_ROOT, d.shader.replace(/^res:\/\//, ''))))
        return `shader "${d.shader}" does not exist in the project`;
      if (typeof d.pad !== 'number' || d.pad < 0) return 'pad must be a non-negative number of px';
      if (d.layer != null && !FILTER_LAYERS.includes(d.layer))
        return `layer must be one of: ${FILTER_LAYERS.join(', ')}`;
      if (d.source != null && !FILTER_SOURCES.includes(d.source))
        return `source must be one of: ${FILTER_SOURCES.join(', ')}`;
      if (d.params != null) {
        if (typeof d.params !== 'object' || Array.isArray(d.params)) return 'params must be an object';
        for (const [k, v] of Object.entries(d.params)) {
          if (!/^[a-z0-9_]+$/.test(k)) return `params key "${k}" must be a shader uniform name (lowercase/underscore)`;
          if (typeof v === 'number') continue;
          if (typeof v === 'string' && /^[0-9a-fA-F]{6}$/.test(v)) continue;
          return `params.${k} must be a number or a 6-digit hex colour`;
        }
        // The effect is clipped to the layer's padded quad, so an OUTWARD spread wider than the
        // padding silently cuts off at the quad's edge — catch it here rather than in a render.
        // pad 0 is exempt: it declares a filter that never spills, whose spread runs INWARD from
        // the silhouette (inner glow), where the quad is the source and nothing can clip.
        if (d.pad > 0 && typeof d.params.spread === 'number' && d.params.spread > d.pad)
          return `params.spread (${d.params.spread}) exceeds pad (${d.pad}) — the effect would clip at the quad's edge`;
      }
      if (!d.concept) return 'missing concept — what this filter is for';
      if (!d.explanation) return 'missing explanation — what it looks like and how it works';
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

// Every .gdshader under the project, as res:// paths — the vocabulary a Render Filter's shader
// field picks from. Walks assets/ only; shaders live with the art they skin.
function scanShaders(rel = 'assets', out = []) {
  const dir = path.join(GAME_ROOT, rel);
  if (!fs.existsSync(dir)) return out;
  for (const f of fs.readdirSync(dir, { withFileTypes: true })) {
    const sub = rel + '/' + f.name;
    if (f.isDirectory()) scanShaders(sub, out);
    else if (f.name.endsWith('.gdshader')) out.push({ id: 'res://' + sub, name: f.name });
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
    sounds: simple('data/sounds'),
    statuses: simple('data/statuses'),
    abilities: simple('data/abilities'),
    charms: simple('data/charms'),
    relics: simple('data/relics'),
    upgrades: simple('data/upgrades'),
    renderFilters: simple('data/render_filters'),
    // Every .gdshader in the project, so a filter's shader is picked from a list rather than
    // typed as a res:// path from memory.
    shaders: scanShaders(),
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
    sideAttrs: SIDE_ATTRS,
    sideSelectors: SIDE_SELECTORS,
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

// ── AudioGen (SFX) ───────────────────────────────────────────────────────────
// The sound twin of ComfyUI: a persistent local server (tools/audiogen/server.py)
// holding Meta's AudioGen warm. The Tool generates CANDIDATE wavs per sound entry
// into workspace/sfx/<id>/, the user auditions them, and installing one copies it
// to assets/sound/ and stamps the entry's `file` field.
function audiogenFetch(urlPath, opts) {
  const base = getSettings().audiogenUrl.replace(/\/$/, '');
  return fetch(base + urlPath, opts);
}

function sfxDir(id) { return path.join(WORKSPACE, 'sfx', id); }

function listSfxCandidates(id) {
  if (!validId(id) || !fs.existsSync(sfxDir(id))) return [];
  return fs.readdirSync(sfxDir(id)).filter(f => f.endsWith('.wav')).sort();
}

// One synchronous generation round-trip (AudioGen holds the GPU; the queue is its own).
async function sfxGenerate({ id, prompt, duration, count, seed }) {
  if (!validId(id)) throw new Error('bad sound id');
  if (!prompt || !String(prompt).trim()) throw new Error('prompt is required');
  let rsp;
  try {
    rsp = await audiogenFetch('/generate', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt: String(prompt), duration: duration || 2,
        count: count || 3, seed, prefix: id }),
    });
  } catch (e) {
    throw new Error('AudioGen server unreachable — start tools/audiogen/start_server.bat');
  }
  const data = await rsp.json().catch(() => ({}));
  if (!rsp.ok || !data.ok) throw new Error(data.error || `AudioGen HTTP ${rsp.status}`);
  ensureDir(sfxDir(id));
  const files = [];
  for (const abs of data.files || []) {
    const name = path.basename(abs);
    fs.copyFileSync(abs, path.join(sfxDir(id), name));
    files.push(name);
  }
  return { files, seconds: data.seconds };
}

// Promote one candidate to THE game asset: assets/sound/<id>.wav + entry.file.
function sfxInstall(id, candidate) {
  if (!validId(id)) throw new Error('bad sound id');
  if (!/^[\w-]+\.wav$/.test(candidate)) throw new Error('bad candidate name');
  const src = path.join(sfxDir(id), candidate);
  if (!fs.existsSync(src)) throw new Error(`no candidate "${candidate}" for "${id}"`);
  const entry = findGameEntry('sound', id);
  if (!entry) throw new Error(`sound "${id}" is not an installed game entry`);
  ensureDir(path.join(GAME_ROOT, 'assets', 'sound'));
  const assetName = id + '.wav';
  fs.copyFileSync(src, path.join(GAME_ROOT, 'assets', 'sound', assetName));
  if (entry.data.file !== assetName) {
    entry.data.file = assetName;
    replaceGameEntry('sound', id, entry.file, entry.data);
  }
  return assetName;
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

// The image "current art" refers to for an item: the workspace-generated art when it
// exists (what the art panel shows as your working image), else the game's installed art.
function currentArtAbs(type, id) {
  // "Current art" = the image the art panel shows as your working art: the workspace-
  // generated image when present, else the deployed in-game art. This mirrors
  // buildArtPreviews / the Flip button ("workspace art preferred, else in-game art"),
  // so every "current" consumer (Flow & batch anchors, recipe inference, single-image
  // reference, recreate-from-art) uses the image you're actually looking at.
  if (fs.existsSync(artPath(type, id))) return artPath(type, id);
  const wsItem = readJson(itemPath(type, id), null);
  const gameEntry = wsItem ? null : findGameEntry(type, id);
  const data = wsItem || (gameEntry && gameEntry.data) || {};
  const rel = gameArtRel(type, id, data);
  if (rel) return path.join(GAME_ROOT, rel);
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

// ── ✨ recipe inference: fill a card's art recipe from its CANONICAL REFS ─────
// The canonical appointments (art guides, exact-composition keys) supply everything:
// the concept ref says what the subject IS, the theme refs say how it is dressed.
// Card refs contribute their stored recipe prompt when they have one (free, exact) and
// their art as a vision reference otherwise; upload refs are always vision references.
// NOTHING is discovered dynamically — the old relative-scoring machinery is gone, and
// a missing appointment REFUSES rather than borrowing from a component overlap.

// Enemy-only cards are outside the canonical system for now (their own pipeline later).
function assertCanonicalEligible(entry) {
  if (entry.data.enemy_only)
    throw new Error('enemy cards are outside the canonical reference system for now');
}

// The two canonical pools for a card. Throws on any missing appointment (mandatory).
function canonicalPools(entry) {
  assertCanonicalEligible(entry);
  const concept = canonicalConceptFor(entry.data.chess_pieces);
  const theme = canonicalThemeFor(entry.data.elements);
  if (!concept && !theme.length)
    throw new Error('this card has no composition (pieces or elements) to resolve canonical references from');
  return { concept: concept ? [concept] : [], theme };
}

// The anchor image for anchored adherence modes, per the user-selected anchor source:
//   current   — the card's own working art; a card with none uses its canonical concept
//   canonical — always the canonical concept ref, ignoring own art
//   custom    — the card's stored recipe reference (tool.art.ref)
// Missing/unresolvable → throws (mandatory; the old silent fall-to-free is gone).
function resolveAnchor(entry) {
  assertCanonicalEligible(entry);
  const mode = getSettings().kinAnchorMode;
  if (mode === 'custom') {
    const ref = entry.data.tool && entry.data.tool.art && entry.data.tool.art.ref;
    const abs = ref ? resolveBatchAnchorRef(entry, ref) : null;
    if (!abs) throw new Error(`no custom reference stored on "${entry.id}" — set one in the art panel, or switch the anchor source`);
    return { id: entry.id, abs, ref: Object.assign({}, ref) };
  }
  if (mode !== 'canonical') {   // 'current'
    const own = currentArtAbs('card', entry.id);
    if (own) return { id: entry.id, abs: own, ref: { source: 'current' } };
  }
  const c = canonicalConceptFor(entry.data.chess_pieces);   // throws when unappointed
  if (!c) throw new Error(`"${entry.id}" has no pieces — no canonical concept applies; use the current-art or custom anchor`);
  return { id: c.name, abs: c.abs, ref: { source: 'upload', path: c.name } };   // frozen asset
}

// Adherence = WHICH INSTRUCTIONS the prompt-writing LLM gets (the user's mental model,
// settled over a long discussion). The question each mode answers is: WHAT carries
// over from the anchor image?
//   replicate — the PICTURE carries: subject, pose, framing; only materials/palette/
//               lighting re-themed. For re-rendering art you already like.
//   concept   — the CONCEPT carries (THE DEFAULT): the anchor's archetype — what kind
//               of unit it is — re-imagined as a NATIVE of the elemental theme. The
//               theme has authority over the embodiment (materials, attire, even the
//               being's nature); the concept keeps it readable as the same KIND of
//               unit, not the same individual. Pose/scene invented fresh.
//   free      — the IDEA carries: loose family blend, no anchor lock.
async function llmInferRecipe(entry, adherence) {
  const alias = { faithful: 'replicate', subject: 'concept' };   // pre-rename names
  adherence = alias[adherence] || adherence;
  adherence = ['replicate', 'concept', 'free'].includes(adherence) ? adherence : 'concept';
  if (adherence !== 'free') return llmInferAnchored(entry, resolveAnchor(entry), adherence);
  return llmInferBlend(entry);
}

async function llmInferAnchored(entry, anchor, adherence) {
  const started = Date.now();
  const d = entry.data;
  assertCanonicalEligible(entry);
  const theme = canonicalThemeFor(d.elements);   // mandatory when the card has elements
  const images = [fs.readFileSync(anchor.abs).toString('base64')];
  const themeLines = [];
  // The theme look rides in as ART-DERIVED captions of the frozen theme assets (cheap,
  // exact, regenerated when the art changes) — never a card's authoring prompt, never an
  // id (an id spells out the composition). Image 1 is the concept anchor; theme is text.
  let tn = 0;
  for (const r of theme) {
    if (anchor.abs && r.abs === anchor.abs) continue;   // the anchor already IS image 1
    tn++;
    themeLines.push(`- theme example ${tn}: "${await refCaption(r.name, r.abs)}"`);
  }
  // "the theme" — never the element names. The look is shown by the theme examples and
  // their reference art; naming the elements is the leak we are closing.
  const task = adherence === 'replicate'
    ? "Describe reference image 1 faithfully — the subject, its pose, the framing and composition — and re-dress it in the theme shown by the examples below: replace ONLY materials, palette, lighting and magical effects. The result must read as the SAME illustration, re-themed."
    : "Identify the CONCEPT of reference image 1 — what kind of unit it is: its role, archetype, build and silhouette. Then write a prompt for a NEW VERSION of that concept, re-imagined as a native of the theme shown by the examples below. The theme decides the embodiment: materials, palette, attire, weaponry and magical nature may all transform to belong to the theme. Keep the result readable as the same KIND of unit — not the same individual. Invent the pose, action, camera angle and setting freely; do not copy the reference's pose or composition.";
  const user = [
    // Authored name = concept + theme identity ("Lightning Hierophant"); name only, never
    // the composition-encoding id (see llmInferBlend).
    d.display_name ? `Card name (the authored concept + theme identity — honor it): ${d.display_name}` : '',
    ...artGuideLines(d.elements, d.chess_pieces),   // opt-in authored composition direction
    ...steerLines(),                                 // always-on free-text steering
    d.art_instructions ? `Author's art direction for this card (follow it): ${d.art_instructions}` : '',
    adherence === 'replicate'
      ? 'Reference image 1 is THE CONCEPT — the exact subject this card\'s art must depict.'
      : 'Reference image 1 is THE CONCEPT — the kind of unit this card depicts; the theme below re-embodies it.',
    themeLines.length ? 'THEME examples (how this theme looks in this game — palette, materials, magic; match it, do not name it):' : '',
    ...themeLines,
    task,
    'Do not name any element, material family, or chess piece — describe only what is seen.',
  ].filter(Boolean).join('\n');
  const out = await llmVisionGenerate({
    system: LLM_SYSTEM_PROMPT + (adherence === 'replicate'
      ? '\nYou are re-theming an existing illustration: reference image 1 is the concept anchor.'
        + ' Carry its specifics into the prompt as instructed — do not reinterpret the subject,'
        + ' and never name an element or chess piece.'
      : '\nYou are fusing a concept with a theme: reference image 1 shows the CONCEPT (what kind'
        + ' of unit this is), the theme examples show the LOOK it must natively belong to. Write'
        + ' their fusion — a theme-native version of the concept, not the same character with'
        + ' theme accents — and never name an element or chess piece.'),
    prompt: user, images, options: { temperature: 0.6, num_predict: 220 },
  });
  const recipe = { prompt: cleanLlmPrompt(out), ref: Object.assign({}, anchor.ref) };
  recipe.inferredFrom = { anchor: anchor.id, theme: theme.map(r => r.name), mode: adherence };
  recipe.stats = { mode: adherence, relatives: theme.length + 1,
    captions: tn, images: images.length, ms: Date.now() - started };
  return recipe;
}

async function llmInferBlend(entry) {
  const started = Date.now();
  const d = entry.data;
  const { concept, theme } = canonicalPools(entry);   // mandatory — throws when unappointed
  // Every canonical ref is a frozen art asset. Each contributes an ART-DERIVED caption
  // (cheap, exact, regenerated when the asset changes) as text; a few also ride along as
  // vision images (theme-first — palette/materials are the visual signal) so the model
  // sees the actual look. Anonymous role labels only, never an id (an id like
  // "air_fire_bishop_queen" spells out the composition — that is the leak we close).
  const IMG_CAP = 3;
  const imgOrder = [];
  for (let k = 0; k < Math.max(theme.length, concept.length); k++) {   // theme-first interleave
    if (theme[k]) imgOrder.push(theme[k]);
    if (concept[k]) imgOrder.push(concept[k]);
  }
  const imgSet = new Set(imgOrder.slice(0, IMG_CAP));
  const images = [];
  const conceptLines = [], themeLines = [];
  for (const [list, out, role] of [[concept, conceptLines, 'concept'], [theme, themeLines, 'theme']]) {
    let n = 0;
    for (const r of list) {
      n++;
      const cap = await refCaption(r.name, r.abs);
      if (imgSet.has(r)) {
        images.push(fs.readFileSync(r.abs).toString('base64'));
        out.push(`- ${role} reference ${n} (see reference image ${images.length}): "${cap}"`);
      } else {
        out.push(`- ${role} reference ${n}: "${cap}"`);
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
    // The card's tooltip/flavour text is deliberately NOT fed in (it is lore, not art
    // direction). The author's per-card Prompt instructions ARE — that field replaced it,
    // and it is honored only when non-empty.
    d.art_instructions ? `Author's art direction for this card (follow it): ${d.art_instructions}` : '',
    conceptLines.length ? 'CONCEPT references — they show what the SUBJECT is:' : '',
    ...conceptLines,
    themeLines.length ? 'THEME references — they show the LOOK (palette, materials, magic); match it from their art/description, do not name it:' : '',
    ...themeLines,
    'Write ONE image prompt: the concept subject rendered in the theme look. Do not name any element, material family, or chess piece — describe only what is seen.',
  ].filter(Boolean).join('\n');
  const out = await llmVisionGenerate({
    system: LLM_SYSTEM_PROMPT +
      "\nYou are inferring the prompt from the card's canonical references: they are grouped as CONCEPT" +
      ' (the subject) and THEME (the look). Blend them — never copy a reference' +
      "'s prompt verbatim, and never name an element or chess piece.",
    prompt: user, images, options: { temperature: 0.8, num_predict: 200 },
  });
  const recipe = { prompt: cleanLlmPrompt(out) };
  // generation reference: the concept asset when present (keeps the subject), else the
  // first theme asset — all canonical refs are frozen uploads now
  const refCand = concept[0] || theme[0] || null;
  if (refCand) recipe.ref = { source: 'upload', path: refCand.name };
  recipe.inferredFrom = { concept: concept.map(r => r.name), theme: theme.map(r => r.name) };
  // what this inference actually cost — surfaced in the UI so slowness is explainable
  recipe.stats = { mode: 'free', relatives: concept.length + theme.length,
    captions: concept.length + theme.length, images: images.length, ms: Date.now() - started };
  return recipe;
}

// ── ✨ recipe inference JOBS ──────────────────────────────────────────────────
// Batch inference runs server-side as a polled job (like art generation): the browser
// starting it can re-render, navigate, even reload — progress lives here, one job per
// file at a time, and /api/state lists running jobs so a fresh page reattaches.
const inferJobs = {};   // jobId -> { id, file, status, total, done, results, error, startedAt }
let inferSeq = 1;
function inferJobForFile(file) {
  return Object.values(inferJobs).find(j => j.file === file
    && (j.status === 'running' || j.status === 'queued')) || null;
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
      // authored recipes are kept unless the run explicitly opts into overwriting
      if (!job.overwrite && entry.data.tool && entry.data.tool.art && entry.data.tool.art.prompt)
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
// Shared verbatim between ✨ effects-from-words and the 💬 edit chat (which writes
// effect objects as op VALUES) — one grammar, two wrappers.
function effectsGrammarLines() {
  const statusIds = listGameEntries('status').map(e => e.id);
  return [
    'An effect object takes ONE of these forms:',
    '1. TRIGGERED — reacts to an event:',
    '   {"trigger": <trigger>, "targets": <targets>, plus a payload: "attribute" one of',
    `   ${EFFECT_ATTRS.join('/')} with numeric "amount", and/or "status": {"id": <status id>,`,
    '   "stacks": n?, "duration": rounds?}. Optional "chance": 0..1.}',
    '   attribute "health": negative amount = direct damage, positive = heal.',
    '   attribute "max_health" raises/lowers the unit\'s maximum health (does not heal).',
    '   attribute "damage_taken" deals damage that consumes shield first.',
    '   attribute "shield" raises/lowers the unit\'s shield BASE — the pool follows it',
    '   (triggered = permanent bump; standing = while the effect holds).',
    `   PLAYER-side payloads ("draw 2 cards", "gain 1 mana"): attribute one of ${SIDE_ATTRS.join('/')}`,
    '   paired with targets {"kind":"side","of":"own"|"opponent"} (and ONLY that pairing:',
    '   side stats never target units, unit stats/statuses never target a side; no conditions).',
    '   "draw" pulls cards deck→hand, "discard" removes random hand cards, "mana"/"max_mana"',
    '   change the current/maximum mana pool. For PASSIVE per-turn quantities ("draw an extra',
    '   card each turn") use a MODIFIER key instead (draw.per_turn etc.), not a side payload.',
    `   <trigger> = {"kind":"event","event": one of ${SIMPLE_EVENTS.join('/')}, "of":"self"?, "conditions":[...]?}`,
    `     or {"kind":"dual_event","event": one of ${DUAL_EVENTS.join('/')}, "origin_of":"self"?,`,
    '     "destination_of":"self"?, "origin_conditions":[...]?, "destination_conditions":[...]?}.',
    '   "of"/"origin_of"/"destination_of":"self" = the event must involve the holder itself;',
    '   omit them to react to anyone\'s event. For dual events, origin = the acting unit',
    '   (e.g. attacker), destination = the receiving unit.',
    '   The "kill" dual event fires when a unit dies: origin = the KILLER unit (present only',
    '   for attack kills; absent for effect/poison kills), destination = the dead unit. Add',
    '   "cause":"poison" (a status id) or "cause":"attack" to match only that kind of kill —',
    '   e.g. "when a unit dies from poison" is {"event":"kill","cause":"poison"}; "when I kill"',
    '   is {"event":"kill","origin_of":"self"} (attacks only, since only attacks credit a unit).',
    '2. STANDING — continuous stat change while the effect is active:',
    '   {"trigger": {"kind":"while"}, "targets": {"kind":"self"} or {"kind":"all","conditions":[...]?},',
    '   "attribute": ..., "amount": n, "tracker": {"kind":"stacks"}?}',
    '   tracker "stacks" = the amount applies PER STACK; omit the tracker otherwise.',
    '   Use STANDING for any ongoing/aura wording ("while", "as long as", buffs from a status).',
    `   Standing attributes fold at read time — legal: health/shield/${FOLDABLE_ATTRS.join('/')}`,
    '   ("health" folds as max_health, "shield" as the shield base). Pools cannot be standing.',
    '   COMPOSITION GRANT — the other standing payload: replace "attribute"/"amount" with',
    `   "grants": [<element/piece ids>] and the target COUNTS AS containing those components`,
    '   for every condition while the effect holds ("counts as fire", "treat as a rook") — its',
    '   real composition never changes. Grants only ever ADD: composition conditions on a',
    '   grant must be positive ("present": false and "has_element": false are rejected).',
    `3. MODIFIER — run-wide passive number change: {"kind":"modifier","key": one of ${MODIFIER_KEYS.join('/')},`,
    '   "amount": n, "conditions":[...]?}. Only for run-wide numbers, never for board effects.',
    '4. INTERCEPTOR — rewrites a pending stat change before it lands: {"kind":"interceptor",',
    `   "intercept": one of ${INTERCEPT_STATS.map(a => `"${a}"`).join('|')},`,
    '   "channel":"attack"|"effect"|"system"|"cost"?,',
    '   "of": {"participant":"source"|"target", "relation":"self"|"ally"|"enemy"|"any"},',
    '   "op":"add"|"mul", "amount": n, "chance":?, "conditions":[...]?}',
    '   The channel is the change\'s PROVENANCE — gate on it to say where it must come from.',
    '   A hit resolves in three interceptable passes: "damage" = the whole hit before the',
    '   shield/health split, then each share on the hit\'s channel — "shield_pool" = what the',
    '   shield is about to absorb, "health" = what is about to wound health. So "block attack',
    '   damage that would reach Health" = intercept "health" + channel "attack", op "mul",',
    '   amount 0 (shares are always reductions; no sign condition needed). Rewritten shares',
    '   never redistribute to each other.',
    '   participant = which side of the change is scrutinised (source caused it, target receives',
    '   it); relation = that unit\'s side vs the effect\'s owner ("self" = must be the holder —',
    '   only meaningful on a card/status, never a relic/upgrade). Conditions gate the participant;',
    '   an interceptor may also use the mutation-form condition (below) to gate on the amount,',
    '   e.g. amount > 0 on "health" = heals only. intercept "status" rewrites the STACK COUNT of',
    '   a status being applied. Intercepting a side stat (e.g. "your draws are doubled" =',
    '   intercept "draw", op "mul"): the target participant is the PLAYER side — relation',
    '   ally/enemy compares that side against the owner; "self" never matches a side.',
    '   Any container can intercept — relics and upgrades included.',
    '   (Legacy spelling "role":"source"|"target" = participant + relation "self".)',
    `5. CUSTOM code hook: {"kind":"custom","custom": one of ${CUSTOM_HOOKS.join('/')}, "trigger":..., "targets":...}`,
    '',
    '<targets> = {"kind":"self"} | {"kind":"all","conditions":[...]?}',
    '  | {"kind":"auto","criterion":"nearest"|"random","count":n?,"conditions":[...]?}',
    '  | {"kind":"manual"} (the player picks a unit) | {"kind":"manual_slot"} (the player picks a slot)',
    `  | {"kind":"participant","participant":"holder"|"origin"|"destination"} (a trigger participant)`,
    '  | {"kind":"side","of":"own"|"opponent"} (a PLAYER — only for side-stat payloads, see above)',
    '',
    'A condition object is ONE of:',
    '  {"allegiance":"ally"|"enemy"} — side relative to the effect\'s owner (ally includes the holder)',
    '  {"status": <status id>, "present": false?} — carrying (or not carrying) a status',
    '  {"composition": [<elements/pieces>...], "present": false?} — made of any of these / none of these',
    '    (standing "grants" count: a unit granted "fire" passes composition/has_element checks as fire)',
    '  {"card_type":"unit"|"spell"} | {"has_element": true|false}',
    `  {"attribute": one of ${COND_ATTRS.join('/')}, "comparator": one of ${COMPARATORS.join('/')}, "value": n}`,
    `  {"mutation":"amount", "comparator": one of ${COMPARATORS.join('/')}, "value": n} — INTERCEPTOR ONLY:`,
    '    a predicate over the pending change\'s amount (e.g. gt 0 = only positive changes/heals)',
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
  ];
}

function effectsSystemPrompt() {
  return [
    "You translate a game designer's plain-English effect description into the game's effect JSON.",
    'Respond with ONLY a JSON array of effect objects — no prose, no markdown fences.',
    '',
    ...effectsGrammarLines(),
  ].join('\n');
}

// Strip think blocks / fences, then parse the first JSON value found (shrinking from
// the right until something parses — tolerates trailing prose).
function extractJson(response) {
  let s = String(response || '')
    .replace(/<think>[\s\S]*?<\/think>/g, '')
    .replace(/```(?:json)?/g, '');
  const start = s.search(/[\[{]/);
  if (start < 0) throw new Error('no JSON in the reply');
  for (let end = s.length; end > start; end--) {
    const cand = s.slice(start, end).trim();
    if (!cand.endsWith(']') && !cand.endsWith('}')) continue;
    try {
      return JSON.parse(cand);
    } catch (e) { /* keep shrinking */ }
  }
  throw new Error('unparseable JSON in the reply');
}

function extractJsonEffects(response) {
  const v = extractJson(response);
  return Array.isArray(v) ? v : [v];
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

// ── 💬 edit chat: conversational blanket edits over the game's content ────────
// The designer chats ("all pawns cost 2 mana; water pawns +2 health"); the LLM
// answers with an OPERATIONS PLAN — field verbs (set / delete / append / remove)
// against entry ids plus a whole-entry `create` — never with rewritten entries, so
// fields it doesn't name physically cannot change. Ops are simulated on copies,
// validateItem gates every touched entry (errors feed a retry, like ✨ effects), and
// NOTHING is written until the user applies the previewed result; each applied entry
// goes through applyGameEdit (or saveGameEntry for created ones), so the normal
// per-entry snapshot/Revert machinery covers chat edits.
const CHAT_OPS = ['set', 'delete', 'append', 'remove', 'create'];

// One catalog line per entry: every top-level field as k=v (JSON, truncated), effects
// as indexed plain-words summaries (the index is the LLM's handle for remove/dot-paths).
// `tool` metadata (art recipes) is noise for content edits and huge — always dropped.
const CHAT_SKIP_FIELDS = new Set(['id', 'display_name', 'effects', 'tool']);
function chatFieldValue(v) {
  const s = JSON.stringify(v);
  return s.length > 200 ? s.slice(0, 200) + '…' : s;
}
function chatCatalog() {
  const lines = [];
  for (const type of Object.keys(TYPES)) {
    const entries = listGameEntries(type);
    if (!entries.length) continue;
    const files = [...new Set(entries.map(e => e.file))].sort();
    lines.push(`## ${type} (${entries.length} entries; files: ${files.join(', ')})`);
    for (const e of entries) {
      const d = e.data;
      const parts = [];
      if (d.display_name && d.display_name !== e.id) parts.push(JSON.stringify(d.display_name));
      for (const [k, v] of Object.entries(d)) {
        if (CHAT_SKIP_FIELDS.has(k) || v === null || v === undefined) continue;
        parts.push(`${k}=${chatFieldValue(v)}`);
      }
      const fx = Array.isArray(d.effects) ? d.effects : [];
      if (fx.length) {
        const noun = FX_OWNER_NOUN[type] || 'the holder';
        parts.push('effects=[' + fx.map((x, i) => `${i}: ${describeEffect(x, noun)}`).join(' | ') + ']');
      }
      lines.push(`- ${e.id}: ${parts.join(' ')}`);
    }
  }
  return lines.join('\n');
}

function chatSystemPrompt() {
  return [
    "You are the content-editing assistant inside a card game's authoring tool.",
    'The designer chats with you to make blanket edits across the game content database.',
    'Every turn you receive the full content catalog and the conversation so far.',
    'Respond with ONLY a JSON object — no prose, no markdown fences — in ONE of these forms:',
    '1. {"reply": "<your answer to the designer>", "ops": [<op>, ...]}',
    '   Propose edits. "reply" says what you did in plain words; empty ops = a pure chat',
    '   answer (questions, advice, asking the designer to clarify).',
    '2. {"reply": "...", "need": [{"type": "<content type>", "ids": ["..."]}]}',
    '   Ask to see the FULL JSON of specific entries first, when a catalog line is too',
    '   terse for the edit (e.g. a truncated field). They arrive on your next turn.',
    '',
    'An op edits ONE field across MANY entries:',
    '  {"type": "<content type>", "ids": ["<entry id>", ...], "op": "set"|"delete"|"append"|"remove",',
    '   "field": "<name or dot.path like effects.0.amount>", "value": <any JSON>?, "index": <n>?}',
    '- set: write "value" at "field" (creates the field if new).',
    '- delete: remove the field entirely.',
    '- append: push "value" onto the LIST at "field" (creates the list if absent).',
    '- remove: delete the item at "index" from the LIST at "field".',
    `Content types: ${Object.keys(TYPES).join(', ')}. ids must come from the catalog.`,
    '',
    'A fifth op creates a brand-new entry (any type except nodeweights):',
    '  {"type": "<content type>", "op": "create", "id": "<new lowercase_id>",',
    '   "file": "<file.json>", "value": {"id": "<same id>", ...the complete entry...}}',
    '- "id" must not already exist; "value" is the whole entry and must carry the same "id".',
    '- "file" is where the entry will live: pick the catalog-listed file of that type whose',
    '  entries it belongs with, or name a new lowercase file for a genuinely new group.',
    '- Later ops in the same plan may reference the created id (e.g. create an ability,',
    '  then append its id to a card\'s "abilities" list).',
    '- Model new entries on similar catalog entries; ask to see one in full ("need") when unsure.',
    '',
    'You cannot delete entries, and ops must never change an existing "id".',
    'To take an entry out of the game, set enabled=false (the game skips disabled entries).',
    'Only propose what the designer asked for — no extra "improvements".',
    '',
    'When a value you write is an effect object (an item of an "effects" list), use the',
    'effect grammar below. The catalog shows current effects as "<index>: <plain words>".',
    '',
    ...effectsGrammarLines(),
  ].join('\n');
}

// Walk a dot path to its parent container; numeric segments index arrays.
function chatResolveParent(root, field) {
  const segs = String(field).split('.');
  let cur = root;
  for (let i = 0; i < segs.length - 1; i++) {
    const k = Array.isArray(cur) ? Number(segs[i]) : segs[i];
    const ok = Array.isArray(cur) ? Number.isInteger(k) && k >= 0 && k < cur.length
      : cur != null && typeof cur === 'object' && k in cur;
    if (!ok) throw new Error(`path "${field}" has nothing at "${segs[i]}"`);
    cur = cur[k];
  }
  if (cur == null || typeof cur !== 'object') throw new Error(`path "${field}" does not lead into an object or list`);
  return { parent: cur, key: Array.isArray(cur) ? Number(segs[segs.length - 1]) : segs[segs.length - 1] };
}

// Apply one op to one entry's data IN PLACE. Throws a designer-readable message.
function applyChatOp(data, op) {
  const { parent, key } = chatResolveParent(data, op.field);
  const isList = Array.isArray(parent);
  if (isList && !(Number.isInteger(key) && key >= 0 && key < parent.length))
    throw new Error(`"${op.field}" is not an existing list index`);
  switch (op.op) {
    case 'set':
      parent[key] = op.value;
      return;
    case 'delete':
      if (isList) parent.splice(key, 1);
      else if (key in parent) delete parent[key];
      else throw new Error(`no field "${op.field}" to delete`);
      return;
    case 'append': {
      if (parent[key] === undefined && !isList) parent[key] = [];
      if (!Array.isArray(parent[key])) throw new Error(`"${op.field}" is not a list`);
      parent[key].push(op.value);
      return;
    }
    case 'remove': {
      if (!Array.isArray(parent[key])) throw new Error(`"${op.field}" is not a list`);
      const i = op.index;
      if (!(Number.isInteger(i) && i >= 0 && i < parent[key].length))
        throw new Error(`"index" ${i} is out of range for "${op.field}" (${parent[key].length} items)`);
      parent[key].splice(i, 1);
      return;
    }
  }
}

// Simulate an ops plan against copies of the current entries. Returns the touched
// entries as { type, id, file, before, after } — created entries carry before: null
// and created: true; throws a message the retry feeds back.
function simulateChatOps(ops) {
  const touched = new Map();
  for (let i = 0; i < ops.length; i++) {
    const op = ops[i] || {};
    const where = `op ${i + 1}`;
    if (!TYPES[op.type]) throw new Error(`${where}: unknown type "${op.type}"`);
    if (!CHAT_OPS.includes(op.op)) throw new Error(`${where}: unknown op "${op.op}" (set/delete/append/remove/create)`);
    if (op.op === 'create') {
      if (op.type === 'nodeweights') throw new Error(`${where}: nodeweights entries cannot be created in chat`);
      if (!validId(op.id)) throw new Error(`${where}: "id" must be lowercase letters, digits and underscores`);
      if (!/^[a-z0-9_]+\.json$/.test(op.file || '')) throw new Error(`${where}: "file" must be a plain lowercase name ending in .json`);
      if (!op.value || typeof op.value !== 'object' || Array.isArray(op.value)) throw new Error(`${where}: "value" must be the complete entry object`);
      if (op.value.id !== op.id) throw new Error(`${where}: "value.id" must equal "${op.id}"`);
      const key = op.type + '/' + op.id;
      if (touched.has(key) || findGameEntry(op.type, op.id)) throw new Error(`${where}: ${key} already exists — create needs a new id`);
      touched.set(key, { type: op.type, id: op.id, file: op.file, created: true,
        before: null, after: JSON.parse(JSON.stringify(op.value)) });
      continue;
    }
    if (typeof op.field !== 'string' || !op.field) throw new Error(`${where}: missing "field"`);
    const ids = Array.isArray(op.ids) ? op.ids : [];
    if (!ids.length) throw new Error(`${where}: "ids" must name at least one entry`);
    for (const id of ids) {
      const key = op.type + '/' + id;
      let t = touched.get(key);
      if (!t) {
        const found = findGameEntry(op.type, id);
        if (!found) throw new Error(`${where}: no ${op.type} "${id}" in the game`);
        t = { type: op.type, id, file: found.file, before: found.data, after: JSON.parse(JSON.stringify(found.data)) };
        touched.set(key, t);
      }
      try { applyChatOp(t.after, op); } catch (e) { throw new Error(`${where} on ${key}: ${e.message}`); }
      if (t.after.id !== id) throw new Error(`${where} on ${key}: ops must never change "id"`);
    }
  }
  return [...touched.values()];
}

// Human-readable per-entry diff lines for the preview ("cost: 1 → 2", "effects + …").
function chatChangeNotes(type, before, after) {
  const notes = [];
  const noun = FX_OWNER_NOUN[type] || 'the holder';
  for (const k of new Set([...Object.keys(before), ...Object.keys(after)])) {
    const a = before[k], b = after[k];
    if (JSON.stringify(a) === JSON.stringify(b)) continue;
    if (k === 'effects') {
      const av = (Array.isArray(a) ? a : []).map(x => describeEffect(x, noun));
      const bv = (Array.isArray(b) ? b : []).map(x => describeEffect(x, noun));
      for (const s of bv.filter(x => !av.includes(x))) notes.push(`effects + ${s}`);
      for (const s of av.filter(x => !bv.includes(x))) notes.push(`effects − ${s}`);
      continue;
    }
    const fmt = v => v === undefined ? '(none)' : chatFieldValue(v);
    notes.push(`${k}: ${fmt(a)} → ${fmt(b)}`);
  }
  return notes;
}

// One chat turn: catalog + conversation → parsed ops → simulate → validate, feeding
// parse/op/validation errors back for up to 6 total generations. A `need` request
// (full entry JSON) also consumes a generation. Persistent failure returns NO changes
// — invalid edits are unappliable, so the designer just rephrases.
async function llmChatEdit(messages) {
  const s = getSettings();
  const system = chatSystemPrompt();
  const convo = messages.map(m => (m.role === 'assistant' ? 'Assistant: ' : 'Designer: ') + m.content).join('\n');
  let user = ['The content catalog (one line per entry):', chatCatalog(), '',
    'Conversation:', convo, '', 'Reply with ONLY the JSON object.'].join('\n');
  let reply = '', lastErr = null;
  for (let attempt = 1; attempt <= 6; attempt++) {
    const out = await llmGenerate({
      model: s.effectsModel || EFFECTS_MODEL_DEFAULT,
      system, prompt: user,
      options: { temperature: 0.2, num_predict: 4000 },
    });
    let msg;
    try {
      msg = extractJson(out.response);
      if (Array.isArray(msg) || typeof msg !== 'object' || msg === null) throw new Error('the reply must be one JSON object');
    } catch (e) {
      lastErr = e.message;
      user += `\nYour previous reply was not usable (${e.message}). Reply with ONLY the JSON object.`;
      continue;
    }
    reply = typeof msg.reply === 'string' ? msg.reply : '';
    if (Array.isArray(msg.need) && msg.need.length) {
      const chunks = [];
      for (const n of msg.need) {
        if (!TYPES[n && n.type]) continue;
        for (const id of (Array.isArray(n.ids) ? n.ids : []).slice(0, 40)) {
          const found = findGameEntry(n.type, id);
          if (!found) { chunks.push(`${n.type}/${id}: (not found)`); continue; }
          const full = Object.assign({}, found.data);
          delete full.tool;
          chunks.push(`${n.type}/${id}: ${JSON.stringify(full)}`);
        }
      }
      user += `\nFull JSON of the entries you asked for:\n${chunks.join('\n') || '(none matched)'}\nNow reply with ONLY the JSON object.`;
      continue;
    }
    const ops = Array.isArray(msg.ops) ? msg.ops : [];
    if (!ops.length) return { reply, ops: [], changes: [], attempts: attempt };
    let changes;
    try {
      changes = simulateChatOps(ops);
    } catch (e) {
      lastErr = e.message;
      user += `\nYou replied: ${JSON.stringify(msg)}\nApplying those ops failed: ${e.message}\nFix the ops and reply with ONLY the JSON object.`;
      continue;
    }
    const errs = changes
      .map(c => { const err = validateItem(c.type, c.after); return err ? `${c.type}/${c.id}: ${err}` : null; })
      .filter(Boolean);
    if (!errs.length) {
      for (const c of changes) c.notes = chatChangeNotes(c.type, c.before || {}, c.after);
      return { reply, ops, changes, attempts: attempt };
    }
    lastErr = errs.join('; ');
    user += `\nYou replied: ${JSON.stringify(msg)}\nThe validator rejected the result: ${lastErr}\nFix the ops and reply with ONLY the JSON object.`;
  }
  return { reply, ops: [], changes: [], warning: lastErr || 'no usable reply', attempts: 6 };
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

// Validate a single-image request, upload its reference, and create the jobs[] shell
// (born 'queued'). Returns { jobId, seed, run } — run() is the awaitable that actually
// drives ComfyUI and lands the image; the generation queue's worker calls it when this
// job reaches the front. (Was startArtJob, which fired run() immediately; the queue owns
// firing now — see enqueue/pump.)
async function prepareArtJob({ type, id, prompt, negative, width, height, steps, guidance, seed, rembg, useRef, refUpload, refGameArt, refMode, denoise, turbo, model }) {
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
  const job = jobs[jobId] = { status: 'queued', type, id, seed: s, startedAt: Date.now(), error: null };
  const run = async () => {
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
  };
  return { jobId, seed: s, run };
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
  return Object.values(flowJobs).find(j => j.type === type && j.itemId === id
    && (j.status === 'running' || j.status === 'queued')) || null;
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
// Dedup by the EXACT card selection, not the file: a whole-file batch and any number of
// single-card quick flows in the same file are distinct requests that all belong in the
// queue. This only short-circuits a true double-submit of the identical selection.
function flowBatchJobForIds(ids) {
  const key = ids.map(String).slice().sort().join(',');
  return Object.values(flowBatchJobs).find(j =>
    (j.status === 'running' || j.status === 'queued')
    && (j.ids || []).map(String).slice().sort().join(',') === key) || null;
}

// The step-1 anchor for one card under the Quick Flow's anchor POLICY.
// A recipe-style stored reference ({source: current|game|upload, path}) → abs path or null.
function resolveBatchAnchorRef(entry, ref) {
  if (!ref) return null;
  if (ref.source === 'current') return currentArtAbs('card', entry.id);
  if (ref.source === 'game') return gameArtAbs(String(ref.path || ''));
  if (ref.source === 'upload') {
    const abs = path.join(WORKSPACE, 'refs', safeRefName(ref.path));
    return fs.existsSync(abs) ? abs : null;
  }
  return null;
}

// Policies: 'current' (own art; none → from scratch), 'canonical' (the appointed concept
// ref — MANDATORY, throws when unappointed), 'custom' (the card's stored recipe ref).
// Legacy stored names: 'base' → canonical, 'recipe' → custom.
function resolveBatchAnchor(entry, policy) {
  if (policy === 'base') policy = 'canonical';
  if (policy === 'recipe') policy = 'custom';
  if (policy === 'current') return currentArtAbs('card', entry.id);
  if (policy === 'canonical') {
    assertCanonicalEligible(entry);
    const c = canonicalConceptFor(entry.data.chess_pieces);   // throws when unappointed
    return c ? c.abs : null;   // null = a pure spell (no pieces): no concept applies
  }
  if (policy === 'custom')
    return resolveBatchAnchorRef(entry, entry.data.tool && entry.data.tool.art && entry.data.tool.art.ref);
  return null;
}

async function runFlowBatchJob(job) {
  const hasRecipe = e => !!(e.data.tool && e.data.tool.art && e.data.tool.art.prompt);
  try {
    // phase 1 (opt-in on engage): fill missing recipes first
    if (job.fill) {
      job.phase = 'recipes';
      // Re-read fresh at EXECUTION time — never job.entries (snapshotted at enqueue). A recipe
      // batch queued AHEAD of this one may have just filled these on disk; honor that and skip
      // them, rather than re-inferring every recipe from a stale pre-queue snapshot.
      const fresh = listGameEntries('card').filter(e => job.ids.includes(e.id));
      const missing = fresh.filter(e => !hasRecipe(e));
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
      let anchorAbs;
      try {
        anchorAbs = resolveBatchAnchor(entry, job.anchorPolicy);
      } catch (e) {
        // a canonical refusal (unappointed slot) skips THIS card, not the whole batch
        job.results.push({ id: entry.id, error: e.message });
        job.done++;
        continue;
      }
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

// ── Generation queue ─────────────────────────────────────────────────────────
// ONE global FIFO of generation REQUESTS, serviced by ONE worker (pump). Every
// generation — single, flow, or Quick Flow batch — routes through here, so ComfyUI
// is only ever driven by one job at a time and a request kicked off while something
// is running lands behind it and starts automatically when the queue reaches it.
//
// An entry's unit of work is the WHOLE runner — the GPU work PLUS its tool-side tail
// (a batch's random pick + applyFlowPick, rembg, pool capture, the front-loaded LLM
// recipe fill). pump() awaits the runner to full completion, so an entry is only
// 'done' once that tail has run and nothing is left dangling when the queue advances.
//
// The underlying job shells (jobs[]/flowJobs[]/flowBatchJobs[]) are created up front
// carrying the SAME id the endpoint returns and born 'queued'; every existing per-job
// poll endpoint therefore keeps working unchanged (it just reports 'queued' until the
// worker starts the job). This queue is a NEW overlay, not a rewrite of those flows.
const genQueue = [];   // entries, oldest first; terminal ones linger as history (pruned)
let queueSeq = 1;
let pumping = false;
const QUEUE_HISTORY = 15;

function isTerminal(s) { return s === 'done' || s === 'error' || s === 'stopped'; }

function enqueue(entry) {
  entry.id = 'q' + queueSeq++;
  entry.status = 'queued';
  entry.error = null;
  entry.enqueuedAt = Date.now();
  entry.startedAt = null;
  entry.finishedAt = null;
  // resolves when the worker finishes this entry — lets an HTTP handler await its turn
  // and then send the result inline (the interactive ✨ endpoints keep their shape).
  entry.done = new Promise(resolve => { entry._resolve = resolve; });
  genQueue.push(entry);
  pump();   // deliberately not awaited
  return entry;
}

// Run one entry to full completion, propagating the underlying job's terminal state.
// The runners record their own errors on the job (they never throw), so we read status.
async function runQueueEntry(entry) {
  const j = entry.jobRef;
  j.status = 'running';
  j.startedAt = Date.now();
  if (entry.kind === 'flow') await runFlowJob(j);
  else if (entry.kind === 'flow-batch') await runFlowBatchJob(j);
  else await entry.run();   // 'generate' | 'prompt' | 'recipe-batch' — run() records on j
  if (j.status === 'error') { entry.error = j.error; return 'error'; }
  return j.status === 'stopped' ? 'stopped' : 'done';
}

function pump() {
  if (pumping) return;
  const entry = genQueue.find(e => e.status === 'queued');
  if (!entry) return;
  pumping = true;
  entry.status = 'running';
  entry.startedAt = Date.now();
  (async () => {
    try {
      entry.status = await runQueueEntry(entry);
    } catch (e) {
      entry.status = 'error';
      entry.error = e.message;
    }
    entry.finishedAt = Date.now();
    if (entry._resolve) entry._resolve(entry);   // wake any HTTP handler awaiting this entry
    pruneQueueHistory();
    pumping = false;
    pump();   // advance to the next queued entry
  })();
}

// Keep at most QUEUE_HISTORY finished entries so the widget shows recent results
// without the list growing without bound.
function pruneQueueHistory() {
  const done = genQueue.filter(e => isTerminal(e.status));
  for (let i = 0; i < done.length - QUEUE_HISTORY; i++) {
    const idx = genQueue.indexOf(done[i]);
    if (idx >= 0) genQueue.splice(idx, 1);
  }
}

// Drop a queued entry's pre-created job shell so it doesn't linger in the registries.
function dropJobShell(e) {
  if (e.kind === 'flow') delete flowJobs[e.jobId];
  else if (e.kind === 'flow-batch') delete flowBatchJobs[e.jobId];
  else if (e.kind === 'recipe-batch') delete inferJobs[e.jobId];
  else if (e.kind === 'prompt') delete promptJobs[e.jobId];
  else if (e.kind === 'generate') delete jobs[e.jobId];
}

// Cancel a still-QUEUED entry: mark its shell stopped, release any HTTP handler awaiting
// it (a queued ✨ prompt has one), and drop the shell. Never called on a running entry.
function cancelQueued(e) {
  if (e.jobRef) e.jobRef.status = 'stopped';
  e.status = 'stopped';
  if (e._resolve) e._resolve(e);
  dropJobShell(e);
}

// Stop the currently-running entry: the same cancel + ComfyUI interrupt the per-flow
// stop buttons use. (generate has no cancel flag of its own — the interrupt aborts its
// in-flight ComfyUI prompt, which surfaces as an error, i.e. a stop.)
function stopRunningEntry(e) {
  const j = e.jobRef;
  if (j) {
    j.cancel = true;
    const cur = j.currentFjobId ? flowJobs[j.currentFjobId] : null;
    if (cur) cur.cancel = true;
  }
  comfyInterrupt();
}

function removeQueueEntry(id) {
  const e = genQueue.find(x => x.id === id);
  if (!e) return { error: 'no such queue entry' };
  if (e.status === 'running') { stopRunningEntry(e); return { ok: true, stopping: true }; }
  if (e.status === 'queued') cancelQueued(e);
  genQueue.splice(genQueue.indexOf(e), 1);
  return { ok: true, removed: true };
}

// which: 'pending' = drop only not-yet-started; 'history' = drop only finished;
// default = both (leaves the running one alone).
function clearQueue(which) {
  const drop = e => which === 'pending' ? e.status === 'queued'
    : which === 'history' ? isTerminal(e.status)
    : (e.status === 'queued' || isTerminal(e.status));
  for (const e of genQueue.filter(drop)) if (e.status === 'queued') cancelQueued(e);
  const keep = genQueue.filter(e => !drop(e));
  genQueue.length = 0;
  genQueue.push(...keep);
}

// The widget's view: entries with live progress pulled from the underlying job.
function queueView() {
  return genQueue.map(e => {
    const j = e.jobRef || {};
    let progress = null;
    if (e.kind === 'flow-batch') progress = { phase: j.phase, done: j.done, total: j.total, currentId: j.currentId };
    else if (e.kind === 'flow') progress = { done: j.done, total: j.total, stepNow: j.stepNow, stepCount: (j.spec || []).length };
    else if (e.kind === 'recipe-batch') progress = { done: j.done, total: j.total };
    else progress = { elapsed: j.startedAt ? Math.round((Date.now() - j.startedAt) / 1000) : 0 };   // 'generate' | 'prompt'
    return { id: e.id, kind: e.kind, label: e.label, status: e.status, jobId: e.jobId,
      error: e.error, refType: e.refType || null, refId: e.refId || null, file: e.file || null,
      progress, enqueuedAt: e.enqueuedAt, startedAt: e.startedAt, finishedAt: e.finishedAt };
  });
}

// Run one LLM/prompt unit of work (work: async () => resultValue) THROUGH the queue,
// then resolve with its result. The interactive ✨ endpoints call this and send the
// result inline, so their response shape is unchanged — the request just waits its turn
// in the single sequence (an image generation for the same item, enqueued after, cannot
// start until this completes). Validation stays in the endpoint (fail fast, right code).
const promptJobs = {};   // pjId -> { status, result, error, startedAt }
let promptSeq = 1;
async function runPromptInQueue(label, ref, work) {
  const jobId = 'pj' + promptSeq++;
  const job = promptJobs[jobId] = { status: 'queued', result: null, error: null, startedAt: Date.now() };
  const entry = enqueue({ kind: 'prompt', label, jobId, jobRef: job,
    refType: ref && ref.type, refId: ref && ref.id,
    run: async () => {
      try { job.result = await work(); job.status = 'done'; }
      catch (e) { job.status = 'error'; job.error = e.message; }
    } });
  await entry.done;
  if (job.status !== 'done') throw new Error(job.error || 'cancelled — removed from the queue');
  return job.result;
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
          // parked = authored but disabled (no live cue site yet) — visible backlog, never deleted
          parked: (e.data && e.data.enabled === false) ? true : undefined,
        }));
      }
      return send(res, 200, {
        gameRoot: GAME_ROOT,
        // running batch-inference jobs, so a fresh/reloaded page reattaches its progress UI
        inferJobs: Object.values(inferJobs).filter(j => j.status === 'running' || j.status === 'queued')
          .map(j => ({ id: j.id, file: j.file, total: j.total, done: j.done })),
        // running (or queued) multi-step flows, same reattachment purpose
        flowJobs: Object.values(flowJobs).filter(j => j.status === 'running' || j.status === 'queued')
          .map(j => ({ id: j.id, type: j.type, itemId: j.itemId, total: j.total, done: j.done })),
        // running (or queued) Quick Flow batches
        flowBatchJobs: Object.values(flowBatchJobs).filter(j => j.status === 'running' || j.status === 'queued')
          .map(j => ({ id: j.id, file: j.file, phase: j.phase, total: j.total, done: j.done })),
        // the generation queue, so a fresh/reloaded page hydrates the monitor widget
        queue: queueView(),
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
      if (body.audiogenUrl) s.audiogenUrl = String(body.audiogenUrl);
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
        if (!['current', 'canonical', 'custom'].includes(body.kinAnchorMode))
          return send(res, 400, { error: `bad kinAnchorMode "${body.kinAnchorMode}"` });
        s.kinAnchorMode = body.kinAnchorMode;
      }
      // kinThemeMode/kinThemeRefs are gone: theme references live in art guides now
      if ('useArtGuides' in body) s.useArtGuides = !!body.useArtGuides;
      if ('kinSteer' in body) s.kinSteer = String(body.kinSteer || '');
      if ('quickFlow' in body) {   // null clears the appointment
        if (body.quickFlow != null) {
          const qfErr = validateFlowSpec(body.quickFlow.steps);
          if (qfErr) return send(res, 400, { error: 'Quick Flow: ' + qfErr });
          if (!['none', 'current', 'canonical', 'custom', 'base', 'recipe'].includes(body.quickFlow.anchor || 'custom'))
            return send(res, 400, { error: 'Quick Flow: bad anchor policy' });
        }
        s.quickFlow = body.quickFlow;
      }
      writeJson(SETTINGS_PATH, s);
      return send(res, 200, { ok: true, settings: s });
    }
    // Art guides + canonical references: composition-keyed, tool-bound. GET returns the
    // table as stored (initial setup ran once at startup — no per-read seeding) plus the
    // composition keys the game actually uses (so the UI lists unappointed ones too). POST
    // replaces the table wholesale (keys normalized to canonical sorted order); any {card}
    // ref is materialized to a frozen snapshot at appoint time, seeded markers kept.
    if (p === '/api/art-guides' && req.method === 'GET')
      return send(res, 200, { ok: true, guides: getArtGuides(), compositions: allCompositions() });
    if (p === '/api/art-guides' && req.method === 'POST') {
      const body = await readBody(req);
      const out = { concept: {}, theme: {} };
      for (const axis of ['concept', 'theme']) {
        const src = body[axis] && typeof body[axis] === 'object' ? body[axis] : {};
        for (const [k, v] of Object.entries(src)) {
          const key = compKey(String(k).split('_').filter(Boolean));
          if (!key || !v || typeof v !== 'object') continue;
          const entry = { label: String(v.label || ''),
            positive: String(v.positive || ''), negative: String(v.negative || '') };
          // canonical reference slots — concept holds one, theme holds a list. A {card}
          // ref is snapshotted to a frozen asset here (materializeRef); only {upload} persists.
          if (axis === 'concept') entry.ref = materializeRef(v.ref);
          else entry.refs = (Array.isArray(v.refs) ? v.refs : []).map(materializeRef).filter(Boolean);
          if (v.seeded) entry.seeded = true;   // keep the marker: cleared slots stay cleared
          out[axis][key] = entry;
        }
      }
      writeJson(GUIDES_PATH, out);
      return send(res, 200, { ok: true, guides: out });
    }
    // Re-apply the spec'd default appointments to ONE composition key (overwrites its refs),
    // snapshotting the default cards' art into frozen assets.
    if (p === '/api/art-guides/seed' && req.method === 'POST') {
      const { axis, key } = await readBody(req);
      if (!['concept', 'theme'].includes(axis) || !key) return send(res, 400, { error: 'bad request' });
      const g = getArtGuides();
      const k = compKey(String(key).split('_').filter(Boolean));
      const entry = g[axis][k] || (g[axis][k] = { label: '', positive: '', negative: '' });
      Object.assign(entry, materializeDefaults(axis, k));
      entry.seeded = true;
      writeJson(GUIDES_PATH, g);
      return send(res, 200, { ok: true, guides: g });
    }
    if (p === '/api/offer-rarity' && req.method === 'GET')
      return send(res, 200, { ok: true, config: getOfferRarity(), pool: offerRarityPool() });
    if (p === '/api/offer-rarity' && req.method === 'POST') {
      const body = await readBody(req);
      const cur = getOfferRarity();
      const num = (v, fb) => (Number.isFinite(v) && v > 0) ? v : fb;
      const out = { piece_rarity: {}, element_rarity: num(body.element_rarity, cur.element_rarity), count_multiplier: {} };
      for (const k of ['pawn', 'knight', 'bishop', 'rook', 'queen', 'king'])
        out.piece_rarity[k] = num(body.piece_rarity && body.piece_rarity[k], cur.piece_rarity[k]);
      const cm = (body.count_multiplier && typeof body.count_multiplier === 'object') ? body.count_multiplier : {};
      for (const k of ['1', '2', '3', '4'])
        out.count_multiplier[k] = num(cm[k], cur.count_multiplier[k]);
      writeJson(OFFER_RARITY_PATH, out);
      return send(res, 200, { ok: true, config: out });
    }
    if (p === '/api/combat-tuning' && req.method === 'GET')
      return send(res, 200, { ok: true, config: getCombatTuning() });
    if (p === '/api/combat-tuning' && req.method === 'POST') {
      // The body may carry either or both keys; each is merged independently against the
      // current config (a dodge-only save never disturbs crit, and vice versa). Negative
      // values fall back to current (rates and multipliers are all >= 0 quantities).
      const body = await readBody(req);
      const cur = getCombatTuning();
      const posOnly = (merged, fallback) => {
        const out = {};
        for (const k of Object.keys(merged))
          out[k] = merged[k] >= 0 ? merged[k] : fallback[k];
        return out;
      };
      const out = {
        dodge: posOnly(mergeTuning(body.dodge, cur.dodge), cur.dodge),
        crit: posOnly(mergeTuning(body.crit, cur.crit), cur.crit),
      };
      writeJson(COMBAT_TUNING_PATH, out);
      return send(res, 200, { ok: true, config: out });
    }
    if (p === '/api/audio-tuning' && req.method === 'GET')
      return send(res, 200, { ok: true, config: Object.assign({ sfx_volume: 0.8, music_volume: 0.5 },
        readJson(AUDIO_TUNING_PATH, {}) || {}) });
    if (p === '/api/audio-tuning' && req.method === 'POST') {
      const body = await readBody(req);
      const cur = Object.assign({ sfx_volume: 0.8, music_volume: 0.5 }, readJson(AUDIO_TUNING_PATH, {}) || {});
      for (const k of ['sfx_volume', 'music_volume']) {
        const v = Number(body[k]);
        if (Number.isFinite(v)) cur[k] = Math.min(1, Math.max(0, v));
      }
      writeJson(AUDIO_TUNING_PATH, cur);
      return send(res, 200, { ok: true, config: cur });
    }
    if (p === '/api/debug-mode' && req.method === 'GET')
      return send(res, 200, Object.assign({ ok: true }, getDebugMode()));
    if (p === '/api/debug-mode' && req.method === 'POST') {
      const body = await readBody(req);
      const enabled = body.enabled !== false;
      writeJson(DEBUG_MODE_PATH, { enabled });
      return send(res, 200, { ok: true, enabled, exists: true });
    }
    if (p === '/api/economy' && req.method === 'GET')
      return send(res, 200, { ok: true, config: getEconomy(), material_ids: MATERIAL_IDS });
    if (p === '/api/economy' && req.method === 'POST') {
      const body = await readBody(req);
      const out = {
        initial: economyBag(body.initial, ECONOMY_DEFAULT.initial, false),
        debug: economyBag(body.debug, ECONOMY_DEFAULT.debug, true),
      };
      writeJson(ECONOMY_PATH, out);
      return send(res, 200, { ok: true, config: out });
    }
    if (p === '/api/game-attributes' && req.method === 'GET')
      return send(res, 200, { ok: true, config: getGameAttrs() });
    if (p === '/api/game-attributes' && req.method === 'POST') {
      // Only registered keys land in the file; all values are >= 0 quantities (bad ones fall
      // back to current), and the king-piece chance is a 0..1 probability.
      const body = await readBody(req);
      const cur = getGameAttrs();
      for (const k of Object.keys(GAME_ATTRS_DEFAULT)) {
        const v = Number(body[k]);
        if (Number.isFinite(v) && v >= 0) cur[k] = v;
      }
      cur['reward.king_piece_chance'] = Math.min(1, cur['reward.king_piece_chance']);
      writeJson(GAME_ATTRS_PATH, cur);
      return send(res, 200, { ok: true, config: cur });
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
    if (p === '/api/audiogen/health') {
      try {
        const r = await audiogenFetch('/health');
        const h = await r.json();
        return send(res, 200, { ok: !!h.ok, model: h.model, device: h.device });
      } catch (e) {
        return send(res, 200, { ok: false, error: e.message });
      }
    }
    if (p === '/api/sfx/generate' && req.method === 'POST') {
      const body = await readBody(req);
      try {
        const out = await sfxGenerate(body);
        return send(res, 200, { ok: true, files: out.files, seconds: out.seconds,
          candidates: listSfxCandidates(String(body.id)) });
      } catch (e) {
        return send(res, 502, { error: e.message });
      }
    }
    if (p === '/api/sfx/candidates') {
      const id = String(url.searchParams.get('id') || '');
      return send(res, 200, { candidates: listSfxCandidates(id) });
    }
    if (p === '/api/sfx/candidate-delete' && req.method === 'POST') {
      const { id, file } = await readBody(req);
      if (!validId(String(id)) || !/^[\w-]+\.wav$/.test(String(file)))
        return send(res, 400, { error: 'bad request' });
      const abs = path.join(sfxDir(String(id)), String(file));
      if (fs.existsSync(abs)) fs.unlinkSync(abs);
      return send(res, 200, { ok: true, candidates: listSfxCandidates(String(id)) });
    }
    if (p === '/api/sfx/install' && req.method === 'POST') {
      const { id, file } = await readBody(req);
      try {
        const assetName = sfxInstall(String(id), String(file));
        return send(res, 200, { ok: true, file: assetName });
      } catch (e) {
        return send(res, 400, { error: e.message });
      }
    }
    if (p === '/api/art/generate' && req.method === 'POST') {
      const body = await readBody(req);
      if (!body.prompt || !String(body.prompt).trim()) return send(res, 400, { error: 'prompt is required' });
      try {
        // validate + upload the reference now (fail fast), then hand the run to the queue
        const prep = await prepareArtJob(body);
        const entry = enqueue({ kind: 'generate', label: `Generate: ${body.id}`,
          jobId: prep.jobId, jobRef: jobs[prep.jobId], run: prep.run,
          refType: body.type, refId: String(body.id) });
        return send(res, 200, { jobId: prep.jobId, seed: prep.seed, queueId: entry.id });
      } catch (e) {
        return send(res, 502, { error: e.message });
      }
    }
    // ── the generation queue (monitor widget) ──
    if (p === '/api/art/queue') return send(res, 200, { queue: queueView() });
    if (p === '/api/art/queue-remove' && req.method === 'POST') {
      const { id } = await readBody(req);
      const out = removeQueueEntry(id);
      return send(res, out.error ? 404 : 200, out);
    }
    if (p === '/api/art/queue-clear' && req.method === 'POST') {
      const { which } = await readBody(req);
      clearQueue(which);
      return send(res, 200, { ok: true, queue: queueView() });
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
        else if (anchor.source === 'canonical') {
          // the appointed canonical concept ref (cards only; mandatory — refuse when missing)
          if (type !== 'card') return send(res, 400, { error: 'canonical references are cards-only' });
          const entry = findGameEntry('card', id);
          if (!entry) return send(res, 400, { error: 'canonical anchor needs a saved game card' });
          try {
            assertCanonicalEligible(entry);
            const c = canonicalConceptFor(entry.data.chess_pieces);
            anchorAbs = c ? c.abs : null;
          } catch (e) { return send(res, 400, { error: e.message }); }
        }
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
      const job = { id: 'flow' + flowSeq++, type, itemId: String(id), status: 'queued',
        total, done: 0, stepNow: 0, nodes: [], prompt: String(prompt),
        negative: negative ? String(negative) : '', spec: steps, anchorAbs,
        anchor: anchorAbs ? { source: anchor.source, path: anchor.path } : null, startedAt: Date.now() };
      flowJobs[job.id] = job;
      enqueue({ kind: 'flow', label: `Flow: ${id}`, jobId: job.id, jobRef: job,
        refType: type, refId: String(id) });   // the queue's worker calls runFlowJob
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
      const running = flowBatchJobForIds(entries.map(e => e.id));
      if (running) return send(res, 200, { ok: true, jobId: running.id, already: true });
      const job = { id: 'fbatch' + flowBatchSeq++, file: jfile, ids: entries.map(e => e.id), entries,
        spec: qf.steps, anchorPolicy: qf.anchor || 'recipe', fill: !!fill, adherence,
        status: 'queued', phase: 'queued', total: entries.length, done: 0,
        results: [], cancel: false, currentId: null, startedAt: Date.now() };
      flowBatchJobs[job.id] = job;
      // single-card quick flows read better as the card id; whole-file as the file
      const label = entries.length === 1 ? `⛓ Quick Flow: ${entries[0].id}`
        : `Batch: ${jfile} (${entries.length} cards)`;
      enqueue({ kind: 'flow-batch', label, jobId: job.id, jobRef: job, file: jfile });
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
      const all = poolManifest(type, id);
      const entry = all.find(e => e.file === String(file));
      const list = all.filter(e => e.file !== String(file));
      try { fs.unlinkSync(path.join(poolDir(type, id), String(file))); } catch (e) { /* gone */ }
      writeJson(path.join(poolDir(type, id), 'pool.json'), list);
      // A flow-born image exists TWICE on disk: the pool copy just removed and the
      // original in the item's _flow dir. Delete the twin too (matched by seed+step),
      // and drop it from the flow manifest so the ⛓ gallery stays truthful. Skipped
      // while a flow is RUNNING for this item (its tree is still being read as refs);
      // that leftover is wiped anyway when the next flow starts.
      if (entry && entry.source === 'flow' && !flowJobForItem(type, String(id))) {
        const fdir = flowDir(type, id);
        const man = readJson(path.join(fdir, 'flow.json'), null);
        if (man && Array.isArray(man.nodes)) {
          const idx = man.nodes.findIndex(nd => nd.seed === entry.seed && nd.step === entry.step);
          if (idx >= 0) {
            try { fs.unlinkSync(path.join(fdir, man.nodes[idx].file)); } catch (e) { /* gone */ }
            man.nodes.splice(idx, 1);
            writeJson(path.join(fdir, 'flow.json'), man);
          }
        }
      }
      return send(res, 200, { ok: true, count: list.length });
    }
    // Permanently delete ALL of an item's generation intermediates from disk: the whole
    // pool, and (unless flows:false) the last flow's candidate images too. The item's
    // workspace art and deployed game art are never touched by this.
    if (p === '/api/art/pool-clear' && req.method === 'POST') {
      const { type, id, flows } = await readBody(req);
      if (!TYPES[type] || !validId(id)) return send(res, 400, { error: 'bad request' });
      if (flowJobForItem(type, String(id)))
        return send(res, 409, { error: 'a flow is running for this item — stop it first' });
      fs.rmSync(poolDir(type, id), { recursive: true, force: true });
      if (flows !== false) fs.rmSync(flowDir(type, id), { recursive: true, force: true });
      return send(res, 200, { ok: true });
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
      const { type, name, summary, example, refArts, concept, refHint, elements, pieces, instructions } = await readBody(req);
      if (!TYPES[type] || !name) return send(res, 400, { error: 'bad request' });
      const refImages = [];
      for (const rel of Array.isArray(refArts) ? refArts.slice(0, 4) : []) {
        const abs = gameArtAbs(rel);
        if (!abs) return send(res, 400, { error: 'reference art not found: ' + rel });
        refImages.push(fs.readFileSync(abs).toString('base64'));
      }
      const guides = [...(type === 'card' ? artGuideLines(elements, pieces) : []), ...steerLines()];
      // the card's per-card Prompt instructions field (authoritative author art direction)
      if (instructions && String(instructions).trim())
        guides.push(`Author's art direction for this card (follow it): ${String(instructions).trim()}`);
      try {
        const prompt = await runPromptInQueue(`✨ Prompt: ${name}`, { type, id: null }, () =>
          llmArtPrompt(TYPES[type].label, String(name),
            Array.isArray(summary) ? summary.map(String) : [], example ? String(example) : '', refImages,
            concept ? String(concept) : '', refHint ? String(refHint) : '', guides));
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
        const prompt = await runPromptInQueue(`✨ From art: ${id}`, { type, id }, () =>
          llmPromptFromArt(type, id, concept ? String(concept) : '', refHint ? String(refHint) : '', guides));
        return send(res, 200, { ok: true, prompt });
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
        const result = await runPromptInQueue(`✨ Recipe: ${id}`, { type: 'card', id }, async () => {
          const recipe = await llmInferRecipe(entry, adherence);
          if (persist) {
            const stats = persistRecipe(entry, recipe);
            return Object.assign({ persisted: true, stats }, recipe);
          }
          return recipe;
        });
        return send(res, 200, Object.assign({ ok: true }, result));
      } catch (e) { return send(res, 502, { error: e.message }); }
    }
    // ✨ recipe inference for a whole FILE — starts a polled server-side JOB (one per
    // file); each inferred recipe is persisted onto its entry as it completes. Entries that
    // already carry a recipe prompt are skipped unless overwrite is set.
    if (p === '/api/art/infer-recipes' && req.method === 'POST') {
      const { type, file, adherence, overwrite } = await readBody(req);
      if (type !== 'card' || !file) return send(res, 400, { error: 'recipe inference is cards-only for now' });
      const entries = listGameEntries('card').filter(e => e.file === file);
      if (!entries.length) return send(res, 404, { error: 'no card entries in ' + file });
      const running = inferJobForFile(file);
      if (running) return send(res, 200, { ok: true, jobId: running.id, already: true });
      const job = { id: 'infer' + inferSeq++, file, adherence, overwrite: !!overwrite,
        status: 'queued', total: entries.length, done: 0, results: [], startedAt: Date.now() };
      inferJobs[job.id] = job;
      enqueue({ kind: 'recipe-batch', label: `✨ Recipes: ${file} (${entries.length})`,
        jobId: job.id, jobRef: job, file, run: () => runInferJob(job, entries) });
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
        const result = await runPromptInQueue(`✨ Effects (${type})`, { type, id: null }, () =>
          llmEffectsFromText(type, text.trim()));
        return send(res, 200, Object.assign({ ok: true }, result));
      } catch (e) {
        return send(res, 502, { error: e.message });
      }
    }
    // 💬 edit chat: one conversational turn → ops plan simulated + validated into a
    // PREVIEW ({changes}); nothing touches the game until /api/chat/apply.
    if (p === '/api/chat/edit' && req.method === 'POST') {
      const { messages } = await readBody(req);
      const list = (Array.isArray(messages) ? messages : [])
        .filter(m => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string' && m.content.trim())
        .slice(-24);
      if (!list.length || list[list.length - 1].role !== 'user')
        return send(res, 400, { error: 'messages must end with a non-empty user message' });
      try {
        const result = await runPromptInQueue('💬 Edit chat', { type: null, id: null }, () => llmChatEdit(list));
        return send(res, 200, Object.assign({ ok: true }, result));
      } catch (e) {
        return send(res, 502, { error: e.message });
      }
    }
    // Apply a previewed chat proposal. Edited entries ride applyGameEdit, created ones
    // saveGameEntry (both snapshot + revert); an entry that changed (or appeared) since
    // its preview is refused, the rest still apply.
    if (p === '/api/chat/apply' && req.method === 'POST') {
      const { changes } = await readBody(req);
      if (!Array.isArray(changes) || !changes.length) return send(res, 400, { error: 'no changes' });
      const applied = [], skipped = [];
      for (const c of changes) {
        const label = `${c && c.type}/${c && c.id}`;
        try {
          if (!c || !TYPES[c.type] || !validId(c.id) || !c.after || c.after.id !== c.id)
            throw new Error('malformed change');
          const cur = findGameEntry(c.type, c.id);
          if (c.created) {
            if (cur) throw new Error('an entry with this id appeared since the preview — ask the chat again');
            saveGameEntry(c.type, c.file, c.after);
          } else {
            if (!cur) throw new Error('entry no longer exists');
            if (JSON.stringify(cur.data) !== JSON.stringify(c.before))
              throw new Error('entry changed since this preview — ask the chat again');
            applyGameEdit(c.type, c.id, c.after, false);
          }
          applied.push(label);
        } catch (e) { skipped.push({ entry: label, error: e.message }); }
      }
      return send(res, 200, { ok: !skipped.length, applied, skipped });
    }
    // Stash a user-provided external image in the workspace as generation reference input.
    if (p === '/api/art/upload-ref' && req.method === 'POST') {
      const { name, dataBase64 } = await readBody(req);
      if (!dataBase64) return send(res, 400, { error: 'dataBase64 is required' });
      const safe = safeRefName(name);
      fs.writeFileSync(path.join(WORKSPACE, 'refs', safe), Buffer.from(dataBase64, 'base64'));
      return send(res, 200, { ok: true, name: safe });
    }
    // uploaded reference previews (workspace/refs — canonical ref slots, flow anchors)
    if (p.startsWith('/refimg/')) {
      const name = safeRefName(decodeURIComponent(p.slice('/refimg/'.length)));
      const abs = path.join(WORKSPACE, 'refs', name);
      if (fs.existsSync(abs)) return send(res, 200, fs.readFileSync(abs), 'image/png');
      return send(res, 404, { error: 'no such reference image' });
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
    // generated SFX candidate audition (workspace/sfx/<id>/<file>.wav)
    if (p.startsWith('/sfxwav/')) {
      const m = p.match(/^\/sfxwav\/([a-z0-9_]+)\/([\w-]+\.wav)$/);
      if (m && fs.existsSync(path.join(sfxDir(m[1]), m[2])))
        return send(res, 200, fs.readFileSync(path.join(sfxDir(m[1]), m[2])), 'audio/wav');
      return send(res, 404, { error: 'no such candidate' });
    }
    // existing game audio preview (read-only) — lets the Sounds tab audition a real asset
    if (p.startsWith('/gamesound/')) {
      const name = decodeURIComponent(p.slice('/gamesound/'.length));
      if (!/^[a-zA-Z0-9._-]+\.(mp3|ogg|wav)$/.test(name)) return send(res, 400, { error: 'bad path' });
      const abs = path.join(GAME_ROOT, 'assets', 'sound', name);
      if (!fs.existsSync(abs)) return send(res, 404, { error: 'not found' });
      const mime = name.endsWith('.mp3') ? 'audio/mpeg' : name.endsWith('.ogg') ? 'audio/ogg' : 'audio/wav';
      return send(res, 200, fs.readFileSync(abs), mime);
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
  try { migrateCanonicalRefs(); }   // one-time: freeze canonical refs into workspace assets
  catch (e) { console.error('canonical-ref migration failed (continuing):', e.message); }
  http.createServer(handle).listen(PORT, '127.0.0.1', () => {
    console.log(`CardGame Authoring Tool  →  http://127.0.0.1:${PORT}`);
    console.log(`Game root: ${GAME_ROOT}`);
  });
}

module.exports = { validateItem, buildFluxWorkflow, buildKrea2Workflow, buildIdeogram4Workflow,
  buildNovaCartoonWorkflow, MODELS, TYPES, gameVocab };
