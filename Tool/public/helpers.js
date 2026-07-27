/* helpers.js — DOM builders + the designer-facing vocabulary (labels, help text,
 * plain-English effect descriptions). Loaded first. */
'use strict';

// ── tiny DOM builder ─────────────────────────────────────────────────────────
function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  if (attrs) for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k === 'html') node.innerHTML = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (k === 'checked' || k === 'disabled' || k === 'hidden' || k === 'selected') { if (v) node[k] = true; }
    else if (k === 'value') node.value = v;
    else node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null) continue;
    node.append(c.nodeType ? c : document.createTextNode(c));
  }
  return node;
}

// ── field widgets (all call onChange() after mutating the draft) ─────────────
function fld(label, input, hint, extraClass) {
  const f = el('label', { class: 'fld' + (extraClass ? ' ' + extraClass : '') },
    el('span', { class: 'lab', text: label }), input);
  if (hint) f.append(el('span', { class: 'hint', text: hint }));
  return f;
}

function textInput(obj, key, onChange, placeholder) {
  return el('input', {
    type: 'text', value: obj[key] == null ? '' : obj[key], placeholder: placeholder || '',
    oninput: e => { obj[key] = e.target.value; onChange(); },
  });
}

function numInput(obj, key, onChange, opts) {
  opts = opts || {};
  return el('input', {
    type: 'number', value: obj[key] == null ? '' : obj[key],
    step: opts.step || 1, min: opts.min, max: opts.max, placeholder: opts.placeholder || '',
    oninput: e => {
      const v = e.target.value;
      if (v === '') { if (opts.optional) delete obj[key]; else obj[key] = 0; }
      else obj[key] = opts.float ? parseFloat(v) : parseInt(v, 10);
      onChange();
    },
  });
}

function checkInput(obj, key, onChange, labelText) {
  return el('label', { class: 'check' },
    el('input', {
      type: 'checkbox', checked: !!obj[key],
      onchange: e => { obj[key] = e.target.checked; onChange(); },
    }),
    labelText || '');
}

function selectInput(obj, key, options, onChange, opts) {
  // options: [{value, label}] or [value]
  opts = opts || {};
  const sel = el('select', {
    onchange: e => {
      if (e.target.value === '' && opts.optional) delete obj[key];
      else obj[key] = e.target.value;
      onChange();
    },
  });
  if (opts.optional) sel.append(el('option', { value: '', text: opts.emptyLabel || '(none)' }));
  for (const o of options) {
    const v = typeof o === 'string' ? o : o.value;
    const l = typeof o === 'string' ? o : o.label;
    sel.append(el('option', { value: v, text: l, selected: obj[key] === v }));
  }
  return sel;
}

// Toggleable chip set editing an array-of-strings in place.
function chipSet(arr, options, onChange, labelFor) {
  const wrap = el('div', { class: 'chipset' });
  for (const o of options) {
    const chip = el('span', {
      class: 'chip' + (arr.includes(o) ? ' on' : ''),
      text: labelFor ? labelFor(o) : o,
      onclick: () => {
        const i = arr.indexOf(o);
        if (i >= 0) arr.splice(i, 1); else arr.push(o);
        chip.classList.toggle('on');
        onChange();
      },
    });
    wrap.append(chip);
  }
  return wrap;
}

function colorInput(obj, key, onChange) {
  // game colours are bare hex strings ("e0a93b")
  const cur = '#' + (obj[key] || 'aaaaaa').replace(/^#/, '');
  return el('input', {
    type: 'color', value: cur,
    oninput: e => { obj[key] = e.target.value.slice(1); onChange(); },
  });
}

function groupBox(title, ...children) {
  return el('div', { class: 'fgroup' }, el('h3', { text: title }), ...children);
}

// ── localized container text (name + description) ────────────────────────────
// Player-facing container text lives in the localization map (data/locale/<lang>.json,
// keyed `<type>.<id>.name/.desc`), NOT the content file. The editor edits a _loc slice on
// the record — { en:{name,desc}, es:{name,desc} } — and mirrors the English into the
// record's display_name/description so list labels, summaries and art prompts keep reading
// them (a transitional mirror; the game itself reads only the locale). See locFields.
const LOC_TAGS = ['air', 'darkness', 'earth', 'fire', 'light', 'water',
  'pawn', 'bishop', 'knight', 'rook', 'queen', 'king',
  'attack', 'health', 'hp', 'mana', 'shield', 'speed'];

function locGet(type, id, lang, f) {
  const t = (typeof state !== 'undefined' && state.locale && state.locale[lang]) || {};
  return (id && t[`${type}.${id}.${f}`]) || '';
}

// Ensure a record carries its _loc slice, seeding from the on-disk locale (or, for a record
// not yet in the map, its legacy display_name/description). Idempotent: the working copy wins
// once present, so edits are never clobbered by a re-render.
function ensureLoc(holder, type) {
  if (holder._loc) return holder._loc;
  const id = holder.id || '';
  holder._loc = {
    en: { name: locGet(type, id, 'en', 'name') || holder.display_name || '',
          desc: locGet(type, id, 'en', 'desc') || holder.description || '' },
    es: { name: locGet(type, id, 'es', 'name'), desc: locGet(type, id, 'es', 'desc') },
  };
  // Keep the transitional content-field mirror in step with the locale source from the start,
  // so list labels / summaries / art prompts read the same English the map holds.
  holder.display_name = holder._loc.en.name;
  holder.description = holder._loc.en.desc;
  return holder._loc;
}

// The English → content-field mirror + change signal, shared by the boxes and the ✦/✨ buttons.
function locSync(holder, onChange) {
  holder.display_name = holder._loc.en.name;
  holder.description = holder._loc.en.desc;
  onChange();
}

// The per-record Text panel: canonical English name + description, Spanish name + description,
// a ✦ "From effects" button (LLM writes the English description from the effect definition),
// and a ✨ "Translate" button (LLM fills Spanish from English, tags/{values} preserved).
// `opts`: { type, onChange, describeLines() -> [strings], typeLabel }.
function locFields(holder, opts) {
  opts = opts || {};
  const type = opts.type;
  const onChange = opts.onChange || (() => {});
  ensureLoc(holder, type);
  const loc = holder._loc;

  const enName = el('input', { type: 'text', value: loc.en.name || '', placeholder: 'English name',
    oninput: e => { loc.en.name = e.target.value; locSync(holder, onChange); } });
  const enDesc = el('textarea', { value: loc.en.desc || '',
    placeholder: 'Mechanical description — wrap game terms in tags, e.g. +2 <attack>, a <fire> <pawn>',
    oninput: e => { loc.en.desc = e.target.value; locSync(holder, onChange); } });
  const esName = el('input', { type: 'text', value: loc.es.name || '', placeholder: loc.en.name || '(español)',
    oninput: e => { loc.es.name = e.target.value; onChange(); } });
  const esDesc = el('textarea', { value: loc.es.desc || '', placeholder: loc.en.desc || '(descripción)',
    oninput: e => { loc.es.desc = e.target.value; onChange(); } });

  const fromBtn = el('button', { class: 'ghost tiny', text: '✦ From effects',
    title: "Write the English description from this item's effects (LLM). Emits <id> term tags." });
  fromBtn.onclick = async () => {
    const lines = opts.describeLines ? opts.describeLines() : [];
    if (!lines.length) { toast('No effects to describe yet', 'err'); return; }
    fromBtn.disabled = true; const t0 = fromBtn.textContent; fromBtn.textContent = '…';
    try {
      const r = await api('/api/locale/describe',
        { typeLabel: opts.typeLabel || type, name: loc.en.name, lines, tags: LOC_TAGS });
      if (r.ok && r.description) { loc.en.desc = r.description; enDesc.value = r.description; locSync(holder, onChange); toast('Description written — review it', 'ok'); }
      else toast('Describe failed: ' + (r.error || '?'), 'err');
    } catch (e) { toast('Describe failed: ' + e.message, 'err'); }
    fromBtn.disabled = false; fromBtn.textContent = t0;
  };

  const trBtn = el('button', { class: 'ghost tiny', text: '✨ Translate → ES',
    title: 'Translate the English name + description into Spanish (LLM). Tags and {values} are kept intact.' });
  trBtn.onclick = async () => {
    if (!(loc.en.name || '').trim() && !(loc.en.desc || '').trim()) { toast('Fill in the English first', 'err'); return; }
    trBtn.disabled = true; const t0 = trBtn.textContent; trBtn.textContent = '…';
    try {
      if ((loc.en.name || '').trim()) {
        const r = await api('/api/locale/translate', { text: loc.en.name, lang: 'es', key: `${type}.${holder.id}.name` });
        if (r.ok && r.translation) { loc.es.name = r.translation; esName.value = r.translation; }
      }
      if ((loc.en.desc || '').trim()) {
        const r = await api('/api/locale/translate', { text: loc.en.desc, lang: 'es', key: `${type}.${holder.id}.desc` });
        if (r.ok && r.translation) { loc.es.desc = r.translation; esDesc.value = r.translation; }
      }
      onChange(); toast('Translated to Spanish — review it', 'ok');
    } catch (e) { toast('Translate failed: ' + e.message, 'err'); }
    trBtn.disabled = false; trBtn.textContent = t0;
  };

  const enDescBtns = el('span', { class: 'loc-inline-btns' });
  if (opts.describeLines) enDescBtns.append(fromBtn);
  return el('div', { class: 'loc-fields' },
    el('div', { class: 'frow' }, fld('Name (English)', enName)),
    el('div', { class: 'fld wide' }, el('span', { class: 'lab' }, 'Description (English)', enDescBtns), enDesc),
    el('div', { class: 'frow' }, fld('Nombre (Español)', esName)),
    el('div', { class: 'fld wide' }, el('span', { class: 'lab' }, 'Descripción (Español)',
      el('span', { class: 'loc-inline-btns' }, trBtn)), esDesc));
}

// The six player-facing effect-container types the localization panel + bulk tools act on.
const CONTAINER_TYPES = ['card', 'relic', 'status', 'ability', 'charm', 'upgrade'];

// The bulk localization bar under the item list: run ✦ generate / ✨ translate across the
// whole FILTERED set (the same records the list shows), scoping the batch by the active filter.
function renderLocBulkBar(type, records) {
  const bar = el('div', { class: 'loc-bulk-bar' });
  const genBtn = el('button', { class: 'ghost small', text: `✦ Descriptions (${records.length})`,
    title: 'Generate the English description from effects for every listed entry that has effects (LLM). Review before it ships.' });
  genBtn.onclick = () => bulkLoc('describe', type, records, genBtn);
  const trBtn = el('button', { class: 'ghost small', text: `✨ Translate → ES (${records.length})`,
    title: "Translate every listed entry's English name + description into Spanish (LLM). Tags/{values} preserved." });
  trBtn.onclick = () => bulkLoc('translate', type, records, trBtn);
  bar.append(genBtn, trBtn);
  return bar;
}

// One localizable subject = one id + its effects. Upgrades expand into the tree PLUS each node,
// since every node carries its own upgrade.<id> text.
function locSubjects(type, records) {
  const subjects = [];
  for (const g of records) {
    const d = g.data || {};
    subjects.push({ id: g.id, effects: d.effects || [], subject: `this ${type}` });
    if (type === 'upgrade') for (const n of d.nodes || [])
      if (n && n.id) subjects.push({ id: n.id, effects: n.effects || [], subject: 'this upgrade' });
  }
  return subjects;
}

async function bulkLoc(mode, type, records, btn) {
  const enText = (id, f) => (state.locale && state.locale.en && state.locale.en[`${type}.${id}.${f}`]) || '';
  const subjects = locSubjects(type, records);
  const label = mode === 'describe' ? 'Generate descriptions' : 'Translate to Spanish';
  if (!confirm(`${label} for ${subjects.length} entr${subjects.length === 1 ? 'y' : 'ies'} with the LLM?\nResults are written to the locale files — review them, they are not final.`)) return;
  btn.disabled = true; const t0 = btn.textContent;
  const entries = {};
  let done = 0, failed = 0, skipped = 0;
  for (const s of subjects) {
    try {
      if (mode === 'describe') {
        const lines = (s.effects || []).map(e => describeEffect(e, s.subject));
        if (!lines.length) { skipped++; }
        else {
          const r = await api('/api/locale/describe', { typeLabel: type, name: enText(s.id, 'name'), lines, tags: LOC_TAGS });
          if (r.ok && r.description) { (entries[`${type}.${s.id}.desc`] = entries[`${type}.${s.id}.desc`] || {}).en = r.description; done++; }
          else failed++;
        }
      } else {
        const nm = enText(s.id, 'name'), ds = enText(s.id, 'desc');
        if (!nm && !ds) { skipped++; }
        else {
          if (nm) { const r = await api('/api/locale/translate', { text: nm, lang: 'es', key: `${type}.${s.id}.name` }); if (r.ok && r.translation) (entries[`${type}.${s.id}.name`] = entries[`${type}.${s.id}.name`] || {}).es = r.translation; }
          if (ds) { const r = await api('/api/locale/translate', { text: ds, lang: 'es', key: `${type}.${s.id}.desc` }); if (r.ok && r.translation) (entries[`${type}.${s.id}.desc`] = entries[`${type}.${s.id}.desc`] || {}).es = r.translation; }
          done++;
        }
      }
    } catch { failed++; }
    btn.textContent = `… ${done + failed + skipped}/${subjects.length}`;
  }
  if (Object.keys(entries).length) {
    try {
      await api('/api/locale/set', { entries });
      state.locale = state.locale || { en: {}, es: {} };
      for (const [key, cell] of Object.entries(entries)) for (const lang of ['en', 'es']) if (lang in cell) {
        state.locale[lang] = state.locale[lang] || {};
        if (cell[lang]) state.locale[lang][key] = cell[lang]; else delete state.locale[lang][key];
      }
    } catch (e) { toast('Bulk locale write failed: ' + e.message, 'err'); }
  }
  btn.disabled = false; btn.textContent = t0;
  toast(`${label}: ${done} done${skipped ? `, ${skipped} skipped` : ''}${failed ? `, ${failed} failed` : ''}`, failed ? 'err' : 'ok');
  // Reflect fresh values in the open editor if it's clean (unsaved edits are left untouched).
  if (state.draft && state.draft.id && !state.dirty) {
    delete state.draft._loc;
    for (const n of state.draft.nodes || []) delete n._loc;
    renderEditor();
  }
}

// Collect a draft's locale entries for /api/locale/set: the record itself plus, for upgrades,
// each of its nodes (which share the upgrade.<id> namespace). Blank cells clear that key.
function collectLocEntries(type, draft) {
  const entries = {};
  const put = (kt, id, loc) => {
    if (!id || !loc) return;
    entries[`${kt}.${id}.name`] = { en: (loc.en.name || '').trim(), es: (loc.es.name || '').trim() };
    entries[`${kt}.${id}.desc`] = { en: (loc.en.desc || '').trim(), es: (loc.es.desc || '').trim() };
  };
  put(type, draft.id, draft._loc);
  if (type === 'upgrade') for (const n of draft.nodes || []) put('upgrade', n.id, n._loc);
  return entries;
}

// ── designer-facing labels ───────────────────────────────────────────────────
const L = {
  trigger: {
    on_play: 'When played onto the board',
    on_death: 'When it dies',
    on_attack: 'Each time it attacks',
    on_damage_taken: 'Each time it takes damage',
    permanent: 'Once, when it enters the board',
    on_turn_start: 'At the start of each round',
    on_turn_end: 'At the end of each round',
    on_activate: 'When its turn comes up',
  },
  // Native trigger events (the resolver schema): every event has an ORIGIN and dual
  // events also a DESTINATION; conditions gate the participants.
  event: {
    transient: 'On use (spell cast / ability activation)',
    play: 'When a unit is played',
    death: 'When a unit dies',
    attack: 'When a unit attacks (before the hit)',
    struck: 'When a unit is struck (after the hit)',
    kill: 'When a unit dies (names the killer / cause)',
    activate: 'When a unit takes its turn',
    turn_start: 'At round start (per unit)',
    turn_end: 'At round end (per unit)',
  },
  // Designer nouns for each event's participants (origin, destination).
  eventOrigin: {
    play: 'The played unit', death: 'The dying unit', attack: 'The attacker',
    struck: 'The attacker', kill: 'The killer (attacks only)', activate: 'The acting unit',
    turn_start: 'The unit whose round it is', turn_end: 'The unit whose round it is',
  },
  eventDestination: { attack: 'The unit being struck', struck: 'The struck unit',
    kill: 'The unit that died' },
  // Identity ("self") is relative to the effect's HOLDER (the unit carrying it — the
  // status's carrier, the card itself); ally/enemy are SIDES relative to the effect's
  // OWNER, which every container has (a relic's owner is the player). See the game's
  // EffectCondition (allegiance) — legacy data spells both as "relation".
  relation: {
    self: 'the holder itself',
    ally: 'an ally of this effect’s owner (holder included)',
    enemy: 'an enemy of this effect’s owner',
  },
  // Native targeting kinds (the TargetResolver schema).
  targetKind: {
    self: 'The holder itself',
    all: 'Every unit matching the conditions',
    auto: 'Auto-pick from matching units',
    manual: 'A unit the player picks',
    manual_slot: 'A slot the player picks (may be empty)',
    participant: 'An event participant (origin / destination)',
    side: 'A player side (own / opponent) — side-stat payloads only',
  },
  // Standing-effect vocabulary: what the payload folds into, and the tracker kinds
  // (the effect's authored lifetime authority — see EffectTracker in the game).
  standingAttr: {
    attack: 'Attack', health: 'Max Health', speed: 'Speed', cost: 'Mana cost',
  },
  trackerKind: {
    container: 'its container exists (status active / card fielded)',
    stacks: 'stacks remain — and the amount SCALES per stack',
  },
  criterion: { nearest: 'nearest to this card', random: 'at random' },
  participant: {
    holder: 'this card itself',
    origin: 'the event ORIGIN (whoever caused it)',
    destination: 'the event DESTINATION (whoever received it)',
  },
  policy: {
    self: 'Itself',
    single_nearest: 'The nearest enemy',
    single_random: 'A random enemy',
    all_enemies: 'Every enemy',
    all_allies: 'Every ally (incl. itself)',
    all: 'Every unit on the board',
    manual: 'A unit the player picks',
    manual_slot: 'A slot the player picks (may be empty)',
    attack_target: 'The unit it is striking',
    attacker: 'The unit that dealt the blow',
    subject: 'The unit the event is about',
  },
  subject: {
    self: 'its own action only',
    ally: 'any ALLY’s action',
    enemy: 'any ENEMY’s action',
    any: 'anyone’s action',
  },
  attr: {
    health: 'Health (heal + / damage −, ignores shield)',
    max_health: 'Max Health (raises the cap, does not heal)',
    damage_taken: 'Damage (hits shield first)',
    attack: 'Attack',
    speed: 'Speed',
    shield: 'Shield',
    cost: 'Mana cost',
    // Side stats (targets kind "side" only — a PLAYER, not a unit).
    draw: 'Draw cards (deck → hand)',
    discard: 'Discard random cards',
    mana: 'Mana (current pool, uncapped above max)',
    max_mana: 'Max mana',
  },
  condAttr: {
    health: 'Health', attack: 'Attack', speed: 'Speed', cost: 'Mana cost',
    piece_count: 'How many chess pieces it holds',
    element_count: 'How many elements it holds',
  },
  cmp: { gt: 'more than', gte: 'at least', lt: 'less than', lte: 'at most', eq: 'exactly', neq: 'anything but' },
  modKey: {
    'unit.attack': 'Unit Attack (your units)',
    'unit.health': 'Unit max Health (your units)',
    'unit.speed': 'Unit Speed (your units)',
    'card.cost': 'Card mana cost (your cards)',
    'mana.initial': 'Starting mana (turn 1)',
    'mana.max': 'Maximum mana (ramp ceiling)',
    'mana.per_turn': 'Bonus mana every turn (stacks above the cap)',
    'hand.size.initial': 'Opening hand size',
    'draw.per_turn': 'Cards drawn per round',
    'gold.initial': 'Starting gold',
    'magic_mineral.initial': 'Starting Magic Mineral (the forge-merge resource)',
    'king.max_health': 'King bonus max Health',
    'relic.capacity': 'Relic slots',
    'reward.essence': 'Bonus essence per combat win',
    'reward.king_piece_chance': 'Chance an Elite drops a King Piece (0–1)',
    'reward.gold.combat': 'Default gold per normal-fight win',
    'reward.gold.elite': 'Default gold per elite win',
    'reward.gold.boss': 'Default gold per boss win',
    'reward.magic_mineral.combat': 'Default Magic Mineral per normal-fight win',
    'reward.magic_mineral.elite': 'Default Magic Mineral per elite win',
    'reward.magic_mineral.boss': 'Default Magic Mineral per boss win',
    'bounty.gold_per_cost': 'Kill bounty — gold per point of the dead unit\'s mana cost',
    'bounty.exp_per_cost': 'Kill bounty — experience per point of the same',
    'bounty.minimum': 'Kill bounty — floor for a derived bounty',
    'forge.cost.per_piece': 'Forge cost per chess-piece component (result)',
    'forge.cost.per_element': 'Forge cost per element component (result)',
    'forge.cost.element_only': 'Forge flat cost — both inputs pure-element',
    'forge.cost.piece_op': 'Forge flat cost — a chess piece is involved',
    'shop.magic_mineral.price': 'Shop gold price of one Magic Mineral',
  },
  hook: {
    rallying_cry: 'Rallying Cry — other allies gain +1 Attack when the subject attacks',
    deliver_material: 'Deliver Material — merges/spawns the ability’s material into the picked slot',
  },
  decay: {
    duration: 'Timer — counts down each round',
    stacks: 'Stacks — count IS the timer (StS poison)',
    none: 'Never — lasts the whole fight',
    intercept: 'Charges — one spent per blocked/rewritten hit',
  },
  stacking: {
    refresh: 'Refresh — reset the timer, no stacking',
    extend: 'Extend — add durations together',
    stack: 'Stack — +1 stack, effects scale with count',
    independent: 'Independent — separate instances',
  },
  element: { fire: 'Fire', water: 'Water', air: 'Air', earth: 'Earth', darkness: 'Darkness', light: 'Light' },
  piece: { pawn: 'Pawn', knight: 'Knight', bishop: 'Bishop', rook: 'Rook', queen: 'Queen', king: 'King' },
};

function labelOf(dict, key) { return (L[dict] && L[dict][key]) || key; }

// ── plain-English descriptions ───────────────────────────────────────────────
function describeCondition(c) {
  if (!c) return '';
  if (c.relation) return 'is ' + labelOf('relation', c.relation);
  if (c.allegiance) return 'is ' + labelOf('relation', c.allegiance);
  if (c.status) return (c.present === false ? 'not carrying ' : 'carrying ') + c.status;
  if (c.composition) {
    const list = Array.isArray(c.composition) ? c.composition : [c.composition];
    return (c.present === false ? 'made of none of: ' : 'made of any of: ') + list.join(', ');
  }
  if (c.mutation) return `the pending amount ${labelOf('cmp', c.comparator)} ${c.value}`;
  return `${labelOf('condAttr', c.attribute)} ${labelOf('cmp', c.comparator)} ${c.value}`;
}

function signed(n) { return (n > 0 ? '+' : '') + n; }

function describeEffect(e, ownerNoun) {
  const owner = ownerNoun || 'this';
  if (!e) return '';
  if (e.trigger && typeof e.trigger === 'object' && e.trigger.kind === 'while') {
    // STANDING: live while its tracker is, folded into stats at read time.
    const tgt = e.targets && e.targets.kind === 'all'
      ? 'every unit' + ((e.targets.conditions || []).length
          ? ` (${e.targets.conditions.map(describeCondition).join(' and ')})` : '')
      : `${owner} itself`;
    const per = e.tracker && e.tracker.kind === 'stacks' ? ' per stack' : '';
    if (Array.isArray(e.grants) && e.grants.length) {
      // Composition grant: the target COUNTS AS containing these for condition resolution.
      const ids = e.grants.map(g => labelOf('element', g) !== g ? labelOf('element', g) : labelOf('piece', g));
      return `While active: ${tgt} counts as ${ids.join(', ')}.`;
    }
    const attr = e.attribute === 'health' ? 'max Health' : labelOf('attr', e.attribute).split(' (')[0];
    return `While active: ${signed(e.amount || 0)} ${attr}${per} to ${tgt}.`;
  }
  const kind = e.kind || (e.key ? 'modifier' : e.intercept ? 'interceptor' : e.custom ? 'custom' : 'triggered');
  if (kind === 'modifier') {
    let s = `Passive: ${labelOf('modKey', e.key)} ${signed(e.amount || 0)}`;
    if (e.filter && e.filter.kind) s += ` (only ${e.filter.kind}s)`;
    if (e.filter && e.filter.has_element) s += ' (element cards only)';
    if (e.conditions && e.conditions.length)
      s += ` — only for cards ${e.conditions.map(describeCondition).join(' and ')}`;
    return s + '.';
  }
  if (kind === 'interceptor') {
    const chan = e.channel ? `${e.channel} ` : '';
    const stat = e.intercept === 'status' ? 'status stacks' : (e.intercept || 'damage');
    let verb;
    if (e.op === 'mul') verb = e.amount === 0 ? 'is fully blocked' : `is multiplied ×${e.amount}`;
    else verb = `is shifted by ${signed(e.amount || 0)}`;
    let s;
    if (e.of && typeof e.of === 'object') {
      // Native relational gate: which mutation participant is scrutinised + its relation.
      const part = e.of.participant === 'source' ? 'caused by' : 'received by';
      const rel = e.of.relation === 'self' ? owner
        : e.of.relation === 'ally' ? 'an ally'
        : e.of.relation === 'enemy' ? 'an enemy' : 'anyone';
      s = `Pending ${chan}${stat} ${part} ${rel} ${verb}`;
    } else {
      const side = e.role === 'target' ? 'incoming' : 'outgoing';
      s = `The holder’s ${side} ${chan}${stat} ${verb}`;
    }
    if (e.conditions && e.conditions.length)
      s += ` — where ${e.conditions.map(describeCondition).join(' and ')}`;
    if (e.chance != null && e.chance !== 1) s += ` (${Math.round(e.chance * 100)}% of the time)`;
    return s + '.';
  }
  // triggered / custom
  let when, subj = '';
  if (e.trigger && typeof e.trigger === 'object') {
    // native resolver form: event + participant condition lists
    const t = e.trigger;
    if (t.kind === 'transient') {
      when = labelOf('event', 'transient');
    } else {
      when = labelOf('event', t.event);
      const gates = [];
      if (t.of === 'self' || t.origin_of === 'self') gates.push('its own');
      if (t.destination_of === 'self') gates.push('it is the destination');
      const oc = t.kind === 'dual_event' ? t.origin_conditions : t.conditions;
      if (oc && oc.length)
        gates.push(`origin ${oc.map(describeCondition).join(' and ')}`);
      if (t.kind === 'dual_event' && t.destination_conditions && t.destination_conditions.length)
        gates.push(`destination ${t.destination_conditions.map(describeCondition).join(' and ')}`);
      if (gates.length) subj = ' — where ' + gates.join('; ');
    }
  } else {
    when = labelOf('trigger', e.trigger || 'on_play');
    if (e.subject && e.subject !== 'self') subj = ` — reacting to ${labelOf('subject', e.subject)}`;
    if (e.subject_elements && e.subject_elements.length) subj += ` (subject must be ${e.subject_elements.join('/')})`;
  }
  let who;
  if (e.targets && typeof e.targets === 'object') {
    const tg = e.targets;
    const conds = (tg.conditions || []).map(describeCondition).join(' and ');
    if (tg.kind === 'self') who = 'itself';
    else if (tg.kind === 'participant') who = labelOf('participant', tg.participant || 'holder');
    else if (tg.kind === 'auto') who = `${tg.count > 1 ? tg.count + ' units' : 'one unit'} ${labelOf('criterion', tg.criterion || 'nearest')}`;
    else if (tg.kind === 'manual') who = 'a unit the player picks';
    else if (tg.kind === 'manual_slot') who = 'a slot the player picks';
    else if (tg.kind === 'side') who = tg.of === 'opponent' ? 'the OPPONENT player' : 'YOUR side';
    else who = 'every unit';
    if (conds && tg.kind !== 'participant') who += ` (${conds})`;
    else if (conds) who += ` (if ${conds})`;
  } else {
    who = labelOf('policy', e.targeting_policy || 'self');
  }
  const parts = [];
  if (kind === 'custom') {
    parts.push(labelOf('hook', e.custom));
  } else {
    if (e.attribute) {
      const amt = e.amount || 0;
      if (e.attribute === 'health') parts.push(amt >= 0 ? `heal ${amt} Health` : `deal ${-amt} direct damage`);
      else if (e.attribute === 'damage_taken') parts.push(`deal ${amt} damage (shield first)`);
      else if (e.attribute === 'draw') parts.push(`draw ${amt} card${amt === 1 ? '' : 's'}`);
      else if (e.attribute === 'discard') parts.push(`discard ${amt} random card${amt === 1 ? '' : 's'}`);
      else if (e.attribute === 'mana') parts.push(amt >= 0 ? `gain ${amt} mana` : `lose ${-amt} mana`);
      else if (e.attribute === 'max_mana') parts.push(`${signed(amt)} max mana`);
      else parts.push(`${signed(amt)} ${labelOf('attr', e.attribute).split(' (')[0]}`);
    }
    if (e.status && e.status.id) {
      let st = `apply ${e.status.stacks || 1}× ${e.status.id}`;
      if (e.status.duration != null && e.status.duration !== -9999) st += ` for ${e.status.duration} rounds`;
      parts.push(st);
    }
  }
  if (!parts.length) parts.push('(no payload yet)');
  let s = `${when}${subj} → ${who}: ${parts.join(' and ')}`;
  if (e.conditions && e.conditions.length && !(e.targets && typeof e.targets === 'object'))
    s += ` — only if ${e.conditions.map(describeCondition).join(' and ')}`;
  if (e.chance != null && e.chance !== 1) s += ` (${Math.round(e.chance * 100)}% chance)`;
  return s + '.';
}

function describeCost(cost) {
  if (!cost) return 'free, taps the holder';
  const bits = [];
  if (cost.mana) bits.push(`${cost.mana} mana`);
  bits.push(cost.tap === false ? 'does NOT tap the holder' : 'taps the holder for the round');
  return bits.join(', ');
}

// escape for use in prompts etc.
function slugToName(id) {
  return (id || '').split('_').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
}

// The plain-English describers are pure functions — the server requires them too
// (few-shot example pairs for the ✨ effects-from-words prompt), so English↔JSON
// stays a single source in both directions.
if (typeof module !== 'undefined' && module.exports)
  module.exports = { describeEffect, describeCondition, labelOf, slugToName };
