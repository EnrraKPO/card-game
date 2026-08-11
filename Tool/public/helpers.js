/* helpers.js — DOM builders + the designer-facing vocabulary (labels, help text).
 * Loaded first. */
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
// and a ✨ "Translate" button (LLM fills Spanish from English, tags/{values} preserved).
// (The ✦ "describe from effects" button died with the effect layer 2026-08-11 — the
// description IS the authored source now: it is the re-authoring brief.)
// `opts`: { type, onChange, typeLabel }.
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

  return el('div', { class: 'loc-fields' },
    el('div', { class: 'frow' }, fld('Name (English)', enName)),
    el('div', { class: 'fld wide' }, el('span', { class: 'lab' }, 'Description (English)'), enDesc),
    el('div', { class: 'frow' }, fld('Nombre (Español)', esName)),
    el('div', { class: 'fld wide' }, el('span', { class: 'lab' }, 'Descripción (Español)',
      el('span', { class: 'loc-inline-btns' }, trBtn)), esDesc));
}

// The six player-facing localizable container types the panel + bulk tools act on.
const CONTAINER_TYPES = ['card', 'relic', 'status', 'ability', 'charm', 'upgrade'];

// The bulk localization bar under the item list: run ✨ translate across the whole
// FILTERED set (the same records the list shows), scoping the batch by the active filter.
// (The ✦ bulk describe-from-effects died with the effect layer 2026-08-11.)
function renderLocBulkBar(type, records) {
  const bar = el('div', { class: 'loc-bulk-bar' });
  const trBtn = el('button', { class: 'ghost small', text: `✨ Translate → ES (${records.length})`,
    title: "Translate every listed entry's English name + description into Spanish (LLM). Tags/{values} preserved." });
  trBtn.onclick = () => bulkLoc(type, records, trBtn);
  bar.append(trBtn);
  return bar;
}

// One localizable subject = one id. Upgrades expand into the tree PLUS each node,
// since every node carries its own upgrade.<id> text.
function locSubjects(type, records) {
  const subjects = [];
  for (const g of records) {
    const d = g.data || {};
    subjects.push({ id: g.id });
    if (type === 'upgrade') for (const n of d.nodes || [])
      if (n && n.id) subjects.push({ id: n.id });
  }
  return subjects;
}

async function bulkLoc(type, records, btn) {
  const enText = (id, f) => (state.locale && state.locale.en && state.locale.en[`${type}.${id}.${f}`]) || '';
  const subjects = locSubjects(type, records);
  const label = 'Translate to Spanish';
  if (!confirm(`${label} for ${subjects.length} entr${subjects.length === 1 ? 'y' : 'ies'} with the LLM?\nResults are written to the locale files — review them, they are not final.`)) return;
  btn.disabled = true; const t0 = btn.textContent;
  const entries = {};
  let done = 0, failed = 0, skipped = 0;
  for (const s of subjects) {
    try {
      const nm = enText(s.id, 'name'), ds = enText(s.id, 'desc');
      if (!nm && !ds) { skipped++; }
      else {
        if (nm) { const r = await api('/api/locale/translate', { text: nm, lang: 'es', key: `${type}.${s.id}.name` }); if (r.ok && r.translation) (entries[`${type}.${s.id}.name`] = entries[`${type}.${s.id}.name`] || {}).es = r.translation; }
        if (ds) { const r = await api('/api/locale/translate', { text: ds, lang: 'es', key: `${type}.${s.id}.desc` }); if (r.ok && r.translation) (entries[`${type}.${s.id}.desc`] = entries[`${type}.${s.id}.desc`] || {}).es = r.translation; }
        done++;
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
// (The old effect schema's vocabulary — triggers, events, targeting kinds, modifier keys,
// payload attributes — died with the effect layer 2026-08-11. The new schema brings its
// own vocabulary with its builder.)
const L = {
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

function signed(n) { return (n > 0 ? '+' : '') + n; }

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

