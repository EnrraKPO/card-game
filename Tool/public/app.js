/* app.js — application shell: state, sidebar, editor lifecycle, art panel,
 * install/uninstall, settings. */
'use strict';

const state = {
  types: {}, items: {}, game: {}, vocab: null, settings: {},
  currentType: 'card', currentId: null,
  draft: null, isNew: false, dirty: false,
  mode: 'ws',           // 'ws' = workspace item, 'game' = editing existing game content in place
  gameFile: null,       // source file of the game entry being edited
  gameEdited: false,    // whether the open game entry has a recorded edit (restorable)
  gameFilter: '',
  gameTree: {},         // per-type { file: expanded } state of the Game-content tree
  artJob: null,
  advancedOpen: false,  // the fullscreen art generator (same _art draft as the panel)
  artRefs: null,        // ranked reference cards for the advanced browser (null = loading)
  refFilter: '',        // reference browser: free-text filter (session-level)
  refEnemyFilter: 'all', // reference browser: 'all' | 'player' | 'enemy'
};

const $ = id => document.getElementById(id);

function toast(msg, kind) {
  const t = el('div', { class: 'toast' + (kind ? ' ' + kind : ''), text: msg });
  $('toast-root').append(t);
  setTimeout(() => t.remove(), kind === 'err' ? 7000 : 3500);
}

async function api(path, body) {
  const res = await fetch(path, body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

async function refreshState(keepEditor) {
  const s = await api('/api/state');
  state.types = s.types; state.items = s.items; state.game = s.game || {};
  state.vocab = s.vocab; state.settings = s.settings;
  state.artModels = s.artModels || { flux2: { label: 'Flux 2 dev', steps: 20, guidance: 4.0, supportsRef: true, supportsTurbo: true } };
  // batch-inference jobs run SERVER-side — reattach progress polling to any the server
  // reports, so a re-render or even a full page reload never loses a running batch
  for (const j of s.inferJobs || []) attachInferPoll(j.file, j.id);
  for (const j of s.flowBatchJobs || []) attachFlowBatchPoll(j.file, j.id);
  state.flowJobsList = s.flowJobs || [];   // running multi-step flows (the ⛓ modal reattaches)
  renderTabs(); renderItemList();
  if (!keepEditor) renderEditor();
  else refreshInstallBar();
}

// ✨ inference adherence — what carries over from a card's anchor image. ONE list AND
// ONE value: settings.kinAdherence is the single source of truth, shown in the card
// list's kin section (buildKinSection, in the art panel) and read by every ✨ action — the per-card quick button,
// the per-file batch, and the art panel dial. Changing it anywhere changes it everywhere.
const KIN_MODES = [
  { value: 'concept', label: 'Same concept — the anchor\'s concept re-imagined natively in the elemental theme' },
  { value: 'replicate', label: 'Replicate — the picture: same pose & framing, re-themed only' },
  { value: 'free', label: 'Free — just the idea: loose family blend' },
];
function kinDefault() { return state.settings.kinAdherence || 'concept'; }
function kinAnchorMode() { return state.settings.kinAnchorMode || 'current'; }
// The ✨ kin controls are ONE global source of truth: every setter persists and refreshes
// the list so all three entry points (per-card quick, per-file batch, editor) read the same.
function setKinField(key, v) {
  state.settings[key] = v;
  const patch = {}; patch[key] = v;
  api('/api/settings', patch).catch(() => {});
  renderItemList();
  if (state.draft) renderArtPanel();
  else renderEmptyKinPanel();
}
function setKinDefault(v) { setKinField('kinAdherence', v); }

// Anchor source for ✨ inference. Theme references are NOT selected here anymore — they
// are canonical appointments per element composition, managed in ✨ Art guides.
const KIN_ANCHOR_MODES = [
  { value: 'current', label: 'Anchor: current art — the card\'s own art (canonical concept when it has none)' },
  { value: 'canonical', label: 'Anchor: canonical — always the appointed canonical concept ref' },
  { value: 'custom', label: 'Anchor: custom — the card\'s stored recipe reference' },
];

// The kin controls — all global, cards only. A collapsible section of the art panel
// (moved out of the sidebar to keep the card list navigable).
function buildKinSection() {
  if (state.currentType !== 'card') return null;
  const parts = [
    el('span', { class: 'lab', text: '✨ kin default' }),
    selectInput({ get v() { return kinDefault(); }, set v(x) { setKinDefault(x); } }, 'v', KIN_MODES, () => {}),
    selectInput({ get v() { return kinAnchorMode(); }, set v(x) { setKinField('kinAnchorMode', x); } }, 'v', KIN_ANCHOR_MODES, () => {}),
    // Quick Flow step-1 anchor — the img2img input each ⛓ run grows from. Lives on the
    // appointment (settings.quickFlow.anchor); shown here so per-CARD ⛓ one-clicks are
    // controllable without opening the per-file batch modal (which edits the same value).
    state.settings.quickFlow ? el('div', { class: 'kin-refs-row' },
      el('span', { class: 'lab', text: '⛓ flow anchor' }),
      selectInput({
        get v() { const a = state.settings.quickFlow.anchor;
          return { base: 'canonical', recipe: 'custom' }[a] || a || 'custom'; },
        set v(x) {
          const qf2 = Object.assign({}, state.settings.quickFlow, { anchor: x });
          state.settings.quickFlow = qf2;
          api('/api/settings', { quickFlow: qf2 }).catch(() => {});
          renderItemList();
        },
      }, 'v', QF_ANCHOR_MODES, () => {})) : null,
    el('div', { class: 'kin-refs-row' },
      el('label', { class: 'check' },
        el('input', { type: 'checkbox', checked: artGuidesEnabled(),
          onchange: e => setKinField('useArtGuides', e.target.checked) }), 'use art guides'),
      el('button', { class: 'ghost tiny', text: 'Edit guides…', onclick: openArtGuidesModal })),
    // always-on free-text steering — empty = inert; persists on blur without a re-render
    el('input', { type: 'text', class: 'kin-steer', placeholder: '✨ steer (optional): a free-text nudge for every generation',
      value: state.settings.kinSteer || '',
      onchange: e => { state.settings.kinSteer = e.target.value;
        api('/api/settings', { kinSteer: e.target.value }).catch(() => {}); } }),
    el('span', { class: 'hint', text: 'what every ✨ recipe inference carries over from a card\'s anchor image' }),
  ].filter(Boolean);
  const details = el('details', Object.assign({ class: 'kin-bar',
    ontoggle: e => { state.kinOpen = e.target.open; } }, state.kinOpen ? { open: 'open' } : {}),
    el('summary', { text: '✨ Recipe defaults (global — every ✨/⛓ action reads these)' }),
    ...parts);
  return details;
}

// With no item open, the editor's empty view still hosts the global kin controls —
// they steer the card list's ✨/⛓ buttons, which work without any selection.
function renderEmptyKinPanel() {
  const p = $('empty-kin-panel');
  if (!p) return;
  if (state.kinOpen == null) state.kinOpen = true;   // default OPEN here: it's the only content
  const kin = buildKinSection();
  p.hidden = !kin;
  p.replaceChildren(...(kin ? [kin] : []));
}
function artGuidesEnabled() { return !!state.settings.useArtGuides; }

// ── ✨ art guides + canonical references editor ───────────────────────────────
// Composition-keyed, two nested levels: an INDEX of the two axes (unit concepts by piece
// composition, element themes by element composition) → a PAGE per composition holding
// its guide text AND its canonical reference slot(s). Concept = exactly one ref; theme =
// one or more. A ref is a card (its deployed art) or an uploaded image. Canonical refs
// are MANDATORY for canonical-anchored generation — an empty slot means refusals.
function openArtGuidesModal() {
  api('/api/art-guides').then(res => {
    const guides = (res && res.guides) || { concept: {}, theme: {} };
    const comps = (res && res.compositions) || { concept: [], theme: [] };
    renderArtGuidesIndex(guides, comps);
  }).catch(err => toast('Could not load art guides: ' + err.message, 'err'));
}

const GUIDE_AXIS_META = {
  concept: { title: 'Unit concepts — by PIECE composition', one: 'concept', hint: 'e.g. bishop_bishop (Hierophant)' },
  theme: { title: 'Element themes — by ELEMENT composition', one: 'theme', hint: 'e.g. air_fire (Lightning)' },
};
function guideRefsOf(axis, entry) {
  if (!entry) return [];
  return axis === 'concept' ? (entry.ref ? [entry.ref] : []) : (entry.refs || []);
}
// A canonical ref → its preview URL (card art via the game list, uploads via /refimg).
function guideRefThumb(ref) {
  if (ref.upload) return '/refimg/' + encodeURIComponent(ref.upload);
  const g = (state.game.card || []).find(x => x.id === ref.card);
  return g && g.art ? '/gameart/' + g.art : null;
}

async function saveArtGuides(guides) {
  await api('/api/art-guides', guides);
}

function renderArtGuidesIndex(guides, comps) {
  const section = axis => {
    // every composition the game uses + any extra authored keys
    const keys = [...new Set([...(comps[axis] || []), ...Object.keys(guides[axis] || {})])].sort();
    const wrap = el('div', { class: 'guide-section' }, el('h3', { text: GUIDE_AXIS_META[axis].title }));
    if (!keys.length) wrap.append(el('div', { class: 'subtle', text: 'No compositions found.' }));
    for (const key of keys) {
      const entry = guides[axis][key];
      const refs = guideRefsOf(axis, entry);
      const hasText = !!(entry && (entry.positive || entry.negative));
      const real = (comps[axis] || []).includes(key);   // backed by an actual game composition?
      wrap.append(el('div', { class: 'guide-index-row', onclick: () => renderArtGuidesPage(guides, comps, axis, key) },
        el('span', { class: 'guide-key', text: key }),
        entry && entry.label ? el('span', { class: 'subtle', text: entry.label }) : null,
        !real ? el('span', { class: 'pill missing', text: 'stray key', title: 'no game card uses this composition — likely a mistake; delete it' }) : null,
        el('span', { class: 'spacer' }),
        hasText ? el('span', { class: 'pill installed', text: '📝 guide' }) : null,
        refs.length ? el('span', { class: 'pill installed', text: `🖼 ${refs.length} ref${refs.length > 1 ? 's' : ''}` })
          : el('span', { class: 'pill missing', text: '⚠ no refs', title: 'canonical-anchored generation will refuse this composition' }),
        entry ? el('button', { class: 'ghost tiny', text: '✕',
          title: real ? 'Delete this entry — the composition stays listed and re-seeds its default refs on next load'
                      : 'Delete this stray entry for good (no game composition uses it)',
          onclick: async e => {
            e.stopPropagation();
            if (!confirm(`Delete the ${axis} entry for "${key}"?` + (real
              ? '\n(A real composition: it re-seeds default refs on next load.)'
              : '\n(A stray key: it will be gone for good.)'))) return;
            delete guides[axis][key];
            try {
              await saveArtGuides(guides);
              toast(`Deleted ${axis} entry "${key}".`, 'ok');
            } catch (err) { toast('Delete failed: ' + err.message, 'err'); }
            renderArtGuidesIndex(guides, comps);
          } }) : null));
    }
    return wrap;
  };
  $('modal-root').replaceChildren(el('div', { class: 'modal', style: 'width:760px; max-height:86vh; overflow:auto' },
    el('h2', {}, '✨ Art guides & canonical references'),
    el('div', { class: 'hint', text: 'Per exact composition: authored guide text (injected when "use art guides" is on) '
      + 'and the CANONICAL references every ✨ inference draws from. No component mixing, ever — a composition without '
      + 'refs refuses canonical-anchored generation.' }),
    section('concept'), section('theme'),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Close', onclick: () => $('modal-root').replaceChildren() }))));
}

function renderArtGuidesPage(guides, comps, axis, key) {
  const entry = guides[axis][key] || (guides[axis][key] = { label: '', positive: '', negative: '' });
  const single = axis === 'concept';
  const rerender = () => renderArtGuidesPage(guides, comps, axis, key);
  const persist = async ok => {
    try { await saveArtGuides(guides); if (ok) toast(ok, 'ok'); }
    catch (err) { toast('Save failed: ' + err.message, 'err'); }
  };

  const setRefs = list => {
    if (single) entry.ref = list[0] || null;
    else entry.refs = list;
  };
  const refs = guideRefsOf(axis, entry);

  const refTile = (ref, i) => {
    const thumb = guideRefThumb(ref);
    return el('div', { class: 'guide-ref-tile' },
      thumb ? el('img', { src: thumb, loading: 'lazy' })
        : el('div', { class: 'guide-ref-broken', text: '⚠ image missing' }),
      el('div', { class: 'subtle', style: 'font-size:11px', text: ref.card || ref.upload }),
      el('button', { class: 'ghost tiny', text: '✕', title: 'Remove this reference', onclick: async () => {
        const list = refs.slice(); list.splice(i, 1); setRefs(list);
        await persist('Reference removed.'); rerender();
      } }));
  };

  // add-a-card picker: any art-bearing card id (free choice — appointing is deliberate)
  const cardIds = (state.game.card || []).filter(g => g.art).map(g => g.id).sort();
  const pick = { id: '' };
  const dl = el('datalist', { id: 'guide-ref-cards' }, ...cardIds.map(id => el('option', { value: id })));
  const addCard = async () => {
    if (!cardIds.includes(pick.id)) { toast('Pick an existing card id (with art).', 'err'); return; }
    const list = single ? [] : refs.slice();
    list.push({ card: pick.id });
    setRefs(list);
    await persist(`Appointed ${pick.id}.`); rerender();
  };
  const uploadInput = el('input', { type: 'file', accept: 'image/*', style: 'display:none',
    onchange: async e => {
      const f = e.target.files && e.target.files[0];
      if (!f) return;
      const dataUrl = await new Promise((res2, rej) => {
        const r = new FileReader(); r.onload = () => res2(r.result); r.onerror = rej; r.readAsDataURL(f);
      });
      try {
        const out = await api('/api/art/upload-ref', { name: f.name, dataBase64: dataUrl.split(',')[1] });
        const list = single ? [] : refs.slice();
        list.push({ upload: out.name });
        setRefs(list);
        await persist(`Uploaded ${out.name}.`); rerender();
      } catch (err) { toast(err.message, 'err'); }
    } });

  $('modal-root').replaceChildren(el('div', { class: 'modal', style: 'width:760px; max-height:86vh; overflow:auto' },
    el('h2', {}, '✨ ', el('span', { class: 'subtle', text: GUIDE_AXIS_META[axis].one + ' · ' }), key),
    el('div', { class: 'frow' },
      fld('Label', textInput(entry, 'label', () => {}, axis === 'concept' ? 'Hierophant' : 'Lightning'))),
    el('label', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Positive — authoritative direction' }),
      el('textarea', { value: entry.positive || '', oninput: e => { entry.positive = e.target.value; } })),
    el('label', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Negative — anti-drift (do NOT depict)' }),
      el('textarea', { value: entry.negative || '', oninput: e => { entry.negative = e.target.value; } })),
    el('h3', { text: single ? 'Canonical concept reference (exactly one)' : 'Canonical theme references (one or more)' }),
    el('div', { class: 'hint', text: single
      ? 'The subject anchor for this piece composition. Default: the bare piece card\'s art.'
      : 'The look/palette references for this exact element composition. Default: its pawn, knight and queen. '
        + 'Any card of this composition (any pieces) or an uploaded image is a valid appointment.' }),
    refs.length ? el('div', { class: 'guide-ref-grid' }, ...refs.map(refTile))
      : el('div', { class: 'pill missing', text: '⚠ no references — canonical-anchored generation refuses this composition' }),
    el('div', { class: 'frow', style: 'margin-top:8px; align-items:flex-end' },
      fld(single ? 'Appoint a card (replaces the slot)' : 'Appoint a card',
        el('input', { type: 'text', list: 'guide-ref-cards', value: '', placeholder: 'card id…',
          oninput: e => { pick.id = e.target.value; } })), dl,
      el('button', { class: 'ghost', text: single ? '✔ appoint' : '+ add card', onclick: addCard }),
      el('button', { class: 'ghost', text: '⬆ upload image…', onclick: () => uploadInput.click() }), uploadInput,
      el('button', { class: 'ghost', text: '⟳ re-seed defaults', title: 'Overwrite the slot(s) with the spec defaults '
        + '(concept: bare piece art; theme: this composition\'s pawn/knight/queen)', onclick: async () => {
          try {
            const out = await api('/api/art-guides/seed', { axis, key });
            Object.assign(guides, out.guides);
            toast('Defaults re-seeded.', 'ok'); renderArtGuidesPage(guides, comps, axis, key);
          } catch (err) { toast(err.message, 'err'); }
        } })),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: '← Back', onclick: async () => {
        await persist(null);   // guide-text edits ride along
        renderArtGuidesIndex(guides, comps);
      } }),
      el('button', { class: 'primary', text: 'Save', onclick: () => persist('Saved.') }))));
}

// ── 🎛 Tuning tab: every global tuning knob as one view of sections ──────────
// Each section below is one global config surface (its own data file + endpoint); the tab
// loads them all and stacks them. Sections save independently — exactly the files the old
// scattered topbar modals wrote.

// ⚖ Offer rarity — how likely each card is to be offered (reward/shop/stage-clear). Reads
// data/offer_rarity.json + the real offerable pool from the server, previews the distribution
// live client-side (mirrors CardData.offer_weight), saves the config back to the game file.
function offerRarityDefaults() {
  return { piece: { pawn: 4, knight: 5, bishop: 5, rook: 5, queen: 20, king: 5 },
    element: 10, count: { '1': 1, '2': 2, '3': 3, '4': 4 } };
}

function offerRaritySection(cfg, pool) {
  let root;
  const TIER = ['', '#5c8a54', '#c0912f', '#cc7433', '#8a5fb0'];
  const PIECES = ['pawn', 'knight', 'bishop', 'rook', 'queen'];
  const COUNTS = [1, 2, 3, 4];

  const weight = card => {
    let r = 1;
    for (let i = 0; i < card.e; i++) r *= cfg.element;
    for (const pc of card.p) r *= (cfg.piece[pc] ?? 5);
    const n = card.e + card.p.length;
    r *= (cfg.count[String(n)] ?? n);
    return r > 0 ? 1 / r : 0;
  };

  const distBox = el('div');
  const update = () => {
    const rows = pool.map(c => ({ n: c.e + c.p.length, w: weight(c) }));
    const total = rows.reduce((s, r) => s + r.w, 0) || 1;
    const bucket = { 1: 0, 2: 0, 3: 0, 4: 0 }, cnt = { 1: 0, 2: 0, 3: 0, 4: 0 };
    rows.forEach(r => { bucket[r.n] = (bucket[r.n] || 0) + r.w / total; cnt[r.n] = (cnt[r.n] || 0) + 1; });
    const max = Math.max(...COUNTS.map(n => bucket[n]), 1e-9);
    const bars = COUNTS.map(n => {
      const pct = bucket[n] * 100, w = bucket[n] / max * 100;
      const lbl = ['', 'Single', 'Two', 'Three', 'Four'][n];
      return el('div', { style: 'display:grid;grid-template-columns:118px 1fr;gap:12px;align-items:center;margin:8px 0' },
        el('div', { style: 'font-size:13px' },
          el('span', { style: `display:inline-block;width:10px;height:10px;border-radius:2px;background:${TIER[n]};margin-right:8px;vertical-align:middle` }),
          lbl + ' ', el('span', { class: 'subtle', text: `${cnt[n] || 0} cards` })),
        el('div', { style: 'position:relative;background:rgba(128,128,128,.2);border-radius:5px;height:26px;overflow:hidden' },
          el('div', { style: `height:100%;width:${w}%;background:${TIER[n]};border-radius:5px;transition:width .25s` }),
          el('div', { style: 'position:absolute;top:0;height:26px;display:flex;align-items:center;padding:0 8px;font-size:12px;font-weight:600', text: pct.toFixed(1) + '%' })));
    });
    const single = bucket[1] * 100, dual = bucket[2] * 100, complex = (bucket[3] + bucket[4]) * 100;
    distBox.replaceChildren(
      el('div', {}, ...bars),
      el('div', { class: 'hint', style: 'margin-top:10px',
        text: `Single ${single.toFixed(1)}%  ·  Dual ${dual.toFixed(1)}%  ·  3–4 piece ${complex.toFixed(1)}%   (pool: ${pool.length} cards)` }));
  };

  const numRow = (label, sub, get, set, min, max, step) => {
    let num;
    const rng = el('input', { type: 'range', min, max, step, value: get(), style: 'flex:1',
      oninput: e => { set(parseFloat(e.target.value)); num.value = e.target.value; update(); } });
    num = el('input', { type: 'number', min, step, value: get(), style: 'width:66px',
      oninput: e => { const v = parseFloat(e.target.value); if (!isNaN(v)) { set(v); rng.value = v; update(); } } });
    return el('div', { style: 'margin:7px 0' },
      el('div', { style: 'display:flex;justify-content:space-between;font-size:13px;margin-bottom:2px' },
        el('span', { text: label }), sub ? el('span', { class: 'subtle', text: sub }) : null),
      el('div', { style: 'display:flex;align-items:center;gap:10px' }, rng, num));
  };

  const controls = el('div', { style: 'flex:1;min-width:270px' },
    el('h3', { text: 'Chess piece rarity' }),
    ...PIECES.map(k => numRow(k[0].toUpperCase() + k.slice(1),
      k === 'pawn' ? 'most common' : (k === 'queen' ? 'rarest' : ''),
      () => cfg.piece[k], v => cfg.piece[k] = v, 1, 60, 0.5)),
    el('h3', { text: 'Element rarity', style: 'margin-top:14px' }),
    numRow('Element', 'all elements equal', () => cfg.element, v => cfg.element = v, 1, 60, 0.5),
    el('h3', { text: 'Count multiplier', style: 'margin-top:14px' }),
    ...COUNTS.map(n => numRow(n + (n === 1 ? ' component' : ' components'), '× rarity',
      () => cfg.count[String(n)], v => cfg.count[String(n)] = v, 0.25, 30, 0.25)));

  root = el('div', { class: 'panel tuning-section' },
    el('h2', {}, '⚖ Offer rarity'),
    el('div', { class: 'hint', text: 'How likely each card is to be offered as a reward, in shops, and on stage clear. '
      + 'Higher rarity = shown less often; every extra component multiplies a card\'s rarity up. '
      + 'Saves to data/offer_rarity.json — restart the game to apply.' }),
    el('div', { style: 'display:flex;gap:26px;flex-wrap:wrap;margin-top:12px' },
      controls,
      el('div', { style: 'flex:1;min-width:290px' }, el('h3', { text: 'Live offer distribution' }), distBox)),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Reset to defaults', onclick: () => {
        const d = offerRarityDefaults();
        Object.assign(cfg.piece, d.piece); cfg.element = d.element; Object.assign(cfg.count, d.count);
        root.replaceWith(offerRaritySection(cfg, pool));
      } }),
      el('button', { class: 'primary', text: 'Save to game', onclick: async () => {
        try {
          await api('/api/offer-rarity', { piece_rarity: cfg.piece, element_rarity: cfg.element, count_multiplier: cfg.count });
          toast('Offer rarity saved — restart the game to apply', 'ok');
        } catch (err) { toast('Save failed: ' + err.message, 'err'); }
      } })));
  update();
  return root;
}

// 🔊 Audio defaults — the game's DEFAULT mixer volumes (data/audio.json) — what the in-game
// settings gear starts from before the player touches anything. Percent model matches the
// game: 80% = as-authored loudness (0 dB), 100% = a slight boost above it.
function audioDefaults() {
  return { sfx_volume: 0.8, music_volume: 0.5 };
}

function audioSection(cfg) {
  let root;
  const pctRow = (label, sub, key) => {
    let num;
    const rng = el('input', { type: 'range', min: 0, max: 100, step: 1, value: Math.round(cfg[key] * 100), style: 'flex:1',
      oninput: e => { cfg[key] = parseFloat(e.target.value) / 100; num.value = e.target.value; } });
    num = el('input', { type: 'number', min: 0, max: 100, step: 1, value: Math.round(cfg[key] * 100), style: 'width:66px',
      oninput: e => { const v = parseFloat(e.target.value); if (!isNaN(v)) { cfg[key] = Math.min(100, Math.max(0, v)) / 100; rng.value = v; } } });
    return el('div', { style: 'margin:10px 0' },
      el('div', { style: 'display:flex;justify-content:space-between;font-size:13px;margin-bottom:2px' },
        el('span', { text: label }), el('span', { class: 'subtle', text: sub })),
      el('div', { style: 'display:flex;align-items:center;gap:10px' }, rng, num));
  };
  root = el('div', { class: 'panel tuning-section' },
    el('h2', {}, '🔊 Audio defaults'),
    el('div', { class: 'hint', text: 'Default mixer volumes shipped with the game — the in-game settings gear starts here, and a player\'s own choices override these on their device. '
      + '80% plays sounds exactly as authored; 100% is a slight boost. Saves to data/audio.json — restart the game to apply.' }),
    el('div', { style: 'max-width:520px' },
      pctRow('Music volume', 'music + ambience beds', 'music_volume'),
      pctRow('SFX volume', 'every one-shot cue and drone', 'sfx_volume')),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Reset to defaults', onclick: () => root.replaceWith(audioSection(Object.assign(cfg, audioDefaults()))) }),
      el('button', { class: 'primary', text: 'Save to game', onclick: async () => {
        try {
          await api('/api/audio-tuning', cfg);
          toast('Audio defaults saved — restart the game to apply', 'ok');
        } catch (err) { toast('Save failed: ' + err.message, 'err'); }
      } })));
  return root;
}

// ⚡ Dodge — global combat balance for DODGE (Resolver.dodge_chance). Reads
// data/combat_tuning.json, lets the four rate knobs be tuned with a live chance table across
// speed match-ups (mirrors the game formula: fixed + per_speed×tgt + per_speed_diff×max(0,
// tgt−atk), capped at max), saves back to the game file.
function dodgeDefaults() {
  return { fixed_pct: 0, per_speed_pct: 1, per_speed_diff_pct: 4, max_pct: 75 };
}

function dodgeSection(cfg) {
  let root;
  // The game's chance formula, in percent (matches Resolver.dodge_chance).
  const chance = (tgtSpeed, atkSpeed) => {
    let pct = cfg.fixed_pct + cfg.per_speed_pct * tgtSpeed;
    const edge = tgtSpeed - atkSpeed;
    if (edge > 0) pct += cfg.per_speed_diff_pct * edge;
    return Math.max(0, Math.min(pct, cfg.max_pct));
  };

  // A speed-vs-speed preview grid: target speed down the rows, attacker speed across the columns.
  const SPEEDS = [0, 1, 2, 3, 4, 5, 6];
  const gridBox = el('div');
  const heat = pct => {
    const t = Math.min(pct / 100, 1);                     // 0..1 toward the cap
    const h = 145, s = 55, l = 22 + t * 30;               // green, brightening with chance
    return `hsl(${h} ${s}% ${l}%)`;
  };
  const update = () => {
    const head = el('tr', {},
      el('th', { style: 'text-align:right;padding:4px 8px;font-size:12px', text: 'tgt ╲ atk' }),
      ...SPEEDS.map(a => el('th', { style: 'padding:4px 8px;font-size:12px;font-weight:600', text: String(a) })));
    const rows = SPEEDS.map(t => el('tr', {},
      el('td', { style: 'text-align:right;padding:4px 8px;font-size:12px;font-weight:600', text: String(t) }),
      ...SPEEDS.map(a => {
        const pct = chance(t, a);
        return el('td', { style: `padding:6px 8px;text-align:center;font-size:12px;background:${heat(pct)};color:#eee;border-radius:4px`,
          text: pct.toFixed(0) + '%' });
      })));
    gridBox.replaceChildren(
      el('table', { style: 'border-collapse:separate;border-spacing:3px;margin-top:4px' }, head, ...rows),
      el('div', { class: 'hint', style: 'margin-top:8px',
        text: 'Chance a target (row speed) dodges an attacker (column speed). The diagonal & below are equal-or-slower targets (per-speed only); above it the target outspeeds and earns the difference bonus. Capped at ' + cfg.max_pct + '%.' }));
  };

  const numRow = (label, sub, key, min, max, step) => {
    let num;
    const rng = el('input', { type: 'range', min, max, step, value: cfg[key], style: 'flex:1',
      oninput: e => { cfg[key] = parseFloat(e.target.value); num.value = e.target.value; update(); } });
    num = el('input', { type: 'number', min, step, value: cfg[key], style: 'width:66px',
      oninput: e => { const v = parseFloat(e.target.value); if (!isNaN(v)) { cfg[key] = v; rng.value = v; update(); } } });
    return el('div', { style: 'margin:7px 0' },
      el('div', { style: 'display:flex;justify-content:space-between;font-size:13px;margin-bottom:2px' },
        el('span', { text: label }), sub ? el('span', { class: 'subtle', text: sub }) : null),
      el('div', { style: 'display:flex;align-items:center;gap:10px' }, rng, num));
  };

  const controls = el('div', { style: 'flex:1;min-width:280px' },
    el('h3', { text: 'Dodge rates', style: 'margin-top:0' }),
    numRow('Fixed', 'flat base chance, every unit', 'fixed_pct', 0, 100, 1),
    numRow('Per speed', '× the target\'s own speed', 'per_speed_pct', 0, 25, 0.5),
    numRow('Per speed advantage', '× how much the target outspeeds the attacker', 'per_speed_diff_pct', 0, 25, 0.5),
    numRow('Max cap', 'hard ceiling on total dodge', 'max_pct', 0, 100, 1));

  root = el('div', { class: 'panel tuning-section' },
    el('h2', {}, '⚡ Dodge tuning'),
    el('div', { class: 'hint', text: 'A unit\'s chance to avoid an attack outright (the whole hit is zeroed). '
      + 'Chance = Fixed + Per-speed × the target\'s speed + Per-speed-advantage × how much faster the target is than its attacker, capped at Max. '
      + 'All values are percentages. Saves to data/combat_tuning.json — restart the game to apply.' }),
    el('div', { style: 'display:flex;gap:26px;flex-wrap:wrap;margin-top:12px' },
      controls,
      el('div', { style: 'flex:1;min-width:330px' }, el('h3', { text: 'Live dodge chance', style: 'margin-top:0' }), gridBox)),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Reset to defaults', onclick: () => root.replaceWith(dodgeSection(Object.assign(cfg, dodgeDefaults()))) }),
      el('button', { class: 'primary', text: 'Save to game', onclick: async () => {
        try {
          await api('/api/combat-tuning', { dodge: cfg });
          toast('Dodge tuning saved — restart the game to apply', 'ok');
        } catch (err) { toast('Save failed: ' + err.message, 'err'); }
      } })));
  update();
  return root;
}

// 💥 Crit — global combat balance for CRIT (Resolver.crit_chance / crit_multiplier) — the
// offensive mirror of the dodge section above, on the same file + endpoint (sibling "crit"
// key). Chance formula: fixed + per_speed × the ATTACKER's speed + per_speed_diff × max(0,
// atk−tgt), capped at max. Plus the damage-multiplier pair: multiplier (the crit factor) and
// multiplier_max (its ceiling, bounding relic bonuses). Saves only the crit key — dodge
// tuning is never disturbed.
function critDefaults() {
  return { fixed_pct: 5, per_speed_pct: 1, per_speed_diff_pct: 0, max_pct: 75,
    multiplier: 2.0, multiplier_max: 5.0 };
}

function critSection(cfg) {
  let root;
  // The game's chance formula, in percent (matches Resolver.crit_chance — attacker-owned).
  const chance = (atkSpeed, tgtSpeed) => {
    let pct = cfg.fixed_pct + cfg.per_speed_pct * atkSpeed;
    const edge = atkSpeed - tgtSpeed;
    if (edge > 0) pct += cfg.per_speed_diff_pct * edge;
    return Math.max(0, Math.min(pct, cfg.max_pct));
  };

  // Attacker speed down the rows, target speed across the columns (the transpose of the dodge
  // grid — crit's owner is the attacker), warm heat ramp to match the cue color.
  const SPEEDS = [0, 1, 2, 3, 4, 5, 6];
  const gridBox = el('div');
  const heat = pct => {
    const t = Math.min(pct / 100, 1);
    const h = 18, s = 60, l = 22 + t * 30;               // red-orange, brightening with chance
    return `hsl(${h} ${s}% ${l}%)`;
  };
  const update = () => {
    const mult = Math.max(1, cfg.multiplier);
    const head = el('tr', {},
      el('th', { style: 'text-align:right;padding:4px 8px;font-size:12px', text: 'atk ╲ tgt' }),
      ...SPEEDS.map(t => el('th', { style: 'padding:4px 8px;font-size:12px;font-weight:600', text: String(t) })));
    const rows = SPEEDS.map(a => el('tr', {},
      el('td', { style: 'text-align:right;padding:4px 8px;font-size:12px;font-weight:600', text: String(a) }),
      ...SPEEDS.map(t => {
        const pct = chance(a, t);
        return el('td', { style: `padding:6px 8px;text-align:center;font-size:12px;background:${heat(pct)};color:#eee;border-radius:4px`,
          text: pct.toFixed(0) + '%' });
      })));
    // Expected damage factor across the board: 1 + chance × (multiplier − 1), at a representative
    // mid-table chance (equal speeds, speed 3) so the multiplier sliders read as real damage.
    const midPct = chance(3, 3) / 100;
    const expected = 1 + midPct * (mult - 1);
    gridBox.replaceChildren(
      el('table', { style: 'border-collapse:separate;border-spacing:3px;margin-top:4px' }, head, ...rows),
      el('div', { class: 'hint', style: 'margin-top:8px',
        text: 'Chance an attacker (row speed) crits a target (column speed). The diagonal & below are equal-or-slower attackers (per-speed only); above it the attacker outspeeds and earns the difference bonus. Capped at ' + cfg.max_pct + '%.' }),
      el('div', { class: 'hint', style: 'margin-top:6px',
        text: `Expected damage at speed 3 vs 3: ×${expected.toFixed(2)} (${(midPct * 100).toFixed(0)}% chance of a ×${mult.toFixed(1)} hit).` }));
  };

  const numRow = (label, sub, key, min, max, step) => {
    let num;
    const rng = el('input', { type: 'range', min, max, step, value: cfg[key], style: 'flex:1',
      oninput: e => { cfg[key] = parseFloat(e.target.value); num.value = e.target.value; update(); } });
    num = el('input', { type: 'number', min, step, value: cfg[key], style: 'width:66px',
      oninput: e => { const v = parseFloat(e.target.value); if (!isNaN(v)) { cfg[key] = v; rng.value = v; update(); } } });
    return el('div', { style: 'margin:7px 0' },
      el('div', { style: 'display:flex;justify-content:space-between;font-size:13px;margin-bottom:2px' },
        el('span', { text: label }), sub ? el('span', { class: 'subtle', text: sub }) : null),
      el('div', { style: 'display:flex;align-items:center;gap:10px' }, rng, num));
  };

  const controls = el('div', { style: 'flex:1;min-width:280px' },
    el('h3', { text: 'Crit chance', style: 'margin-top:0' }),
    numRow('Fixed', 'flat base chance, every attacker', 'fixed_pct', 0, 100, 1),
    numRow('Per speed', '× the attacker\'s own speed', 'per_speed_pct', 0, 25, 0.5),
    numRow('Per speed advantage', '× how much the attacker outspeeds the target', 'per_speed_diff_pct', 0, 25, 0.5),
    numRow('Max cap', 'hard ceiling on total crit chance', 'max_pct', 0, 100, 1),
    el('h3', { text: 'Crit damage', style: 'margin-top:14px' }),
    numRow('Multiplier', 'total damage = base × this on a crit', 'multiplier', 1, 5, 0.1),
    numRow('Multiplier max', 'ceiling on relic-boosted multipliers', 'multiplier_max', 1, 10, 0.1));

  root = el('div', { class: 'panel tuning-section' },
    el('h2', {}, '💥 Crit tuning'),
    el('div', { class: 'hint', text: 'An attacker\'s chance to land a CRITICAL — the post-interception damage is multiplied. '
      + 'Chance = Fixed + Per-speed × the attacker\'s speed + Per-speed-advantage × how much faster the attacker is than its target, capped at Max. '
      + 'Chance values are percentages; the multipliers are damage factors. Saves to data/combat_tuning.json — restart the game to apply.' }),
    el('div', { style: 'display:flex;gap:26px;flex-wrap:wrap;margin-top:12px' },
      controls,
      el('div', { style: 'flex:1;min-width:330px' }, el('h3', { text: 'Live crit chance', style: 'margin-top:0' }), gridBox)),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Reset to defaults', onclick: () => root.replaceWith(critSection(Object.assign(cfg, critDefaults()))) }),
      el('button', { class: 'primary', text: 'Save to game', onclick: async () => {
        try {
          await api('/api/combat-tuning', { crit: cfg });
          toast('Crit tuning saved — restart the game to apply', 'ok');
        } catch (err) { toast('Save failed: ' + err.message, 'err'); }
      } })));
  update();
  return root;
}

// 👑 Game attributes — the global run/match numbers (GameAttributes.DEFAULTS): every game
// system reads these through GameData.value(key). Saves data/game_attributes.json as
// overrides on top of the code defaults (an absent file = pure defaults).
function gameAttrDefaults() {
  return { 'mana.initial': 1, 'mana.max': 10, 'mana.per_turn': 0, 'hand.size.initial': 3,
    'draw.per_turn': 1, 'gold.initial': 100, 'magic_mineral.initial': 5,
    'king.max_health': 0, 'relic.capacity': 10,
    'reward.essence': 0, 'reward.king_piece_chance': 0,
    'reward.gold.combat': 0, 'reward.gold.elite': 0, 'reward.gold.boss': 0,
    'reward.magic_mineral.combat': 2, 'reward.magic_mineral.elite': 3, 'reward.magic_mineral.boss': 5,
    'forge.cost.per_piece': 2, 'forge.cost.per_element': 1,
    'forge.cost.element_only': 0, 'forge.cost.piece_op': 1,
    'shop.magic_mineral.price': 25,
    'ux.hold.duration': 0.4, 'ux.hold.tolerance': 44 };
}

function gameAttributesSection(cfg) {
  let root;
  const numRow = (label, sub, get, set, min, max, step) => {
    let num;
    const rng = el('input', { type: 'range', min, max, step, value: get(), style: 'flex:1',
      oninput: e => { set(parseFloat(e.target.value)); num.value = e.target.value; } });
    num = el('input', { type: 'number', min, step, value: get(), style: 'width:66px',
      oninput: e => { const v = parseFloat(e.target.value); if (!isNaN(v)) { set(v); rng.value = v; } } });
    return el('div', { style: 'margin:7px 0' },
      el('div', { style: 'display:flex;justify-content:space-between;font-size:13px;margin-bottom:2px' },
        el('span', { text: label }), sub ? el('span', { class: 'subtle', text: sub }) : null),
      el('div', { style: 'display:flex;align-items:center;gap:10px' }, rng, num));
  };
  const row = (key, label, sub, min, max, step) =>
    numRow(label, sub, () => cfg[key], v => { cfg[key] = v; }, min, max, step);
  const pctRow = (key, label, sub) =>
    numRow(label, sub, () => Math.round(cfg[key] * 100),
      v => { cfg[key] = Math.min(100, Math.max(0, v)) / 100; }, 0, 100, 1);
  const col = (title, ...rows) =>
    el('div', { style: 'flex:1;min-width:250px' },
      el('h3', { text: title, style: 'margin-top:0' }), ...rows);

  root = el('div', { class: 'panel tuning-section' },
    el('h2', {}, '👑 Game attributes'),
    el('div', { class: 'hint', text: 'The global run/match numbers — every system reads these through GameData.value(), '
      + 'and upgrades/relics stack their modifiers on top. Saves to data/game_attributes.json as overrides on the code defaults — restart the game to apply.' }),
    el('div', { style: 'display:flex;gap:26px;flex-wrap:wrap;margin-top:12px' },
      col('Combat economy',
        row('mana.initial', 'Starting mana', 'crystals on turn 1 (then +1/turn, uncapped)', 0, 10, 1),
        row('mana.per_turn', 'Bonus mana per turn', 'flat extra crystals, stacked on the ramp', 0, 5, 1),
        row('mana.max', 'Mana max', 'UNUSED by the uncapped ramp; still read by arcana upgrades', 0, 20, 1),
        row('hand.size.initial', 'Opening hand', 'cards drawn into the opening hand', 0, 10, 1),
        row('draw.per_turn', 'Draw per turn', 'cards drawn at the start of each round', 0, 5, 1)),
      col('Run economy',
        row('magic_mineral.initial', 'Starting Magic Mineral', 'the run\'s forge-merge resource at run start', 0, 50, 1),
        row('king.max_health', 'King bonus health', 'added on top of the run King card\'s health', 0, 100, 1),
        row('relic.capacity', 'Relic capacity', 'how many relics a run may hold at once', 1, 30, 1)),
      col('Encounter rewards',
        row('reward.essence', 'Bonus essence', 'extra essence granted per combat win', 0, 20, 1),
        pctRow('reward.king_piece_chance', 'King piece chance', '% chance an Elite also drops a King Piece'),
        row('reward.gold.combat', 'Gold — normal fight', 'default gold per win, on top of the encounter\'s authored roll', 0, 200, 1),
        row('reward.gold.elite', 'Gold — elite', '', 0, 200, 1),
        row('reward.gold.boss', 'Gold — boss', '', 0, 500, 1),
        row('reward.magic_mineral.combat', 'Mineral — normal fight', 'default Magic Mineral per win, on top of the authored roll', 0, 20, 1),
        row('reward.magic_mineral.elite', 'Mineral — elite', '', 0, 20, 1),
        row('reward.magic_mineral.boss', 'Mineral — boss', '', 0, 50, 1)),
      col('Forge & shop',
        row('forge.cost.per_piece', 'Cost per chess piece', 'mineral per piece component in the merge RESULT', 0, 20, 1),
        row('forge.cost.per_element', 'Cost per element', 'mineral per element component in the merge result', 0, 20, 1),
        row('forge.cost.element_only', 'Element-only surcharge', 'flat mineral when BOTH inputs are pure-element cards', 0, 20, 1),
        row('forge.cost.piece_op', 'Piece-merge surcharge', 'flat mineral when at least one input holds a chess piece', 0, 20, 1),
        row('shop.magic_mineral.price', 'Mineral shop price', 'gold price of one Magic Mineral in the shop', 0, 500, 5)),
      col('UX',
        row('ux.hold.duration', 'Hold to inspect', 'seconds a touch must be held to open the card details modal', 0.1, 1.5, 0.05),
        row('ux.hold.tolerance', 'Hold drag tolerance', 'viewport px the finger may drift and still count as a hold — '
          + 'a drag starting inside this is provisional and the hold takes it back', 0, 150, 2))),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Reset to defaults', onclick: () => root.replaceWith(gameAttributesSection(Object.assign(cfg, gameAttrDefaults()))) }),
      el('button', { class: 'primary', text: 'Save to game', onclick: async () => {
        try {
          await api('/api/game-attributes', cfg);
          toast('Game attributes saved — restart the game to apply', 'ok');
        } catch (err) { toast('Save failed: ' + err.message, 'err'); }
      } })));
  return root;
}

// 💰 Economy — the starting resources (data/economy.json via EconomyConfig): what a fresh
// profile/run begins with. Two bags side by side — Initial (the shipping economy) and Debug
// (dev overrides: while enabled they REPLACE the initial bag; gold -1 = no override). The
// initial gold knob is the gold.initial attribute (so upgrade modifiers keep stacking on
// it) and saves through /api/game-attributes; everything else saves to /api/economy.
const ECO_ELEMENTS = ['fire', 'water', 'air', 'earth', 'darkness', 'light'];
const ECO_PIECES = ['pawn', 'knight', 'bishop', 'rook', 'queen', 'king'];
function economyDefaults() {
  const debugMats = { king_piece: 21 };
  for (const p of ECO_PIECES) if (p !== 'king') debugMats[p + '_piece'] = 10;
  for (const e of ECO_ELEMENTS) debugMats[e + '_stone'] = 10;
  return {
    initial: { materials: {}, upgrade_points: 0 },
    debug: { enabled: true, gold: -1, magic_mineral: -1, materials: debugMats, upgrade_points: 12 },
  };
}

function economySection(cfg, ga) {
  let root;
  const numField = (label, get, set, min, title) => el('div', { class: 'eco-row', title: title || '' },
    el('span', { text: label }),
    el('input', { type: 'number', min, step: 1, value: get(), style: 'width:70px',
      oninput: e => { const v = parseFloat(e.target.value); if (!isNaN(v)) set(Math.round(v)); } }));
  const matField = (bag, id, label) =>
    numField(label, () => bag.materials[id] || 0,
      v => { if (v > 0) bag.materials[id] = v; else delete bag.materials[id]; }, 0);
  const group = (title, rows) => el('div', { style: 'margin-top:12px' },
    el('div', { class: 'eco-group', text: title }), ...rows);
  const cap = s => s[0].toUpperCase() + s.slice(1);

  const bagCol = (bag, isDebug) => {
    const goldRow = isDebug
      ? numField('Gold', () => bag.gold, v => { bag.gold = Math.max(-1, v); }, -1,
        'Pins the run\'s starting gold while debug is enabled; -1 = no override (normal starting gold applies)')
      : numField('Gold', () => ga['gold.initial'], v => { ga['gold.initial'] = Math.max(0, v); }, 0,
        'The gold.initial attribute — upgrade modifiers stack on top of it');
    // Magic Mineral is RUN-scoped (the forge-merge resource), not a profile material — the
    // initial column edits the magic_mineral.initial attribute; the debug column pins it
    // like gold (-1 = no override).
    const mineralRow = isDebug
      ? numField('Magic Mineral', () => bag.magic_mineral, v => { bag.magic_mineral = Math.max(-1, v); }, -1,
        'Pins the run\'s starting Magic Mineral while debug is enabled; -1 = no override (magic_mineral.initial applies)')
      : numField('Magic Mineral', () => ga['magic_mineral.initial'], v => { ga['magic_mineral.initial'] = Math.max(0, v); }, 0,
        'The magic_mineral.initial attribute — upgrade modifiers stack on top of it');
    return el('div', { style: 'flex:1;min-width:250px;max-width:340px' },
      el('h3', { text: isDebug ? 'Debug overrides' : 'Initial resources', style: 'margin-top:0' }),
      isDebug
        ? el('label', { class: 'check', style: 'display:block;margin:6px 0 2px',
          title: 'While enabled AND the game launches in debug mode (the git-ignored debug.json at the project root, on by default), this whole bag REPLACES the initial resources for fresh profiles/runs' },
          el('input', { type: 'checkbox', checked: bag.enabled, onchange: e => { bag.enabled = e.target.checked; } }),
          ' Enabled — replaces the initial resources (debug launches only)')
        : el('div', { class: 'hint', text: 'What every fresh profile/run starts with in the shipping game.' }),
      group('Purse', [goldRow, mineralRow,
        numField('Upgrade points', () => bag.upgrade_points, v => { bag.upgrade_points = Math.max(0, v); }, 0,
          'Spendable points for the Upgrades skill trees')]),
      group('Elemental essence', ECO_ELEMENTS.map(e => matField(bag, e, cap(e)))),
      group('Elemental stones', ECO_ELEMENTS.map(e => matField(bag, e + '_stone', cap(e) + ' Stone'))),
      group('Chess pieces', ECO_PIECES.map(p => matField(bag, p + '_piece', cap(p) + ' Piece'))));
  };

  root = el('div', { class: 'panel tuning-section' },
    el('h2', {}, '💰 Economy'),
    el('div', { class: 'hint', text: 'The starting resources of a fresh profile/run. Initial = the shipping economy; '
      + 'Debug = dev overrides that replace it entirely while enabled — and only when the game launches in debug mode '
      + '(the git-ignored debug.json at the project root; on by default). Saves to data/economy.json '
      + '(initial gold to data/game_attributes.json) — restart the game to apply.' }),
    el('div', { style: 'display:flex;gap:34px;flex-wrap:wrap;margin-top:12px' },
      bagCol(cfg.initial, false), bagCol(cfg.debug, true)),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Reset to defaults', onclick: () => {
        Object.assign(cfg, economyDefaults());
        ga['gold.initial'] = gameAttrDefaults()['gold.initial'];
        ga['magic_mineral.initial'] = gameAttrDefaults()['magic_mineral.initial'];
        root.replaceWith(economySection(cfg, ga));
      } }),
      el('button', { class: 'primary', text: 'Save to game', onclick: async () => {
        try {
          await api('/api/economy', { initial: cfg.initial, debug: cfg.debug });
          await api('/api/game-attributes', ga);
          toast('Economy saved — restart the game to apply', 'ok');
        } catch (err) { toast('Save failed: ' + err.message, 'err'); }
      } })));
  return root;
}

// The tab body: load every global config in parallel, fold each onto its client defaults
// (missing keys keep their defaults — same round-trip the old modals did), then one sub-tab
// per section. The configs live in this closure, so unsaved edits survive sub-tab switches.
async function renderTuningView() {
  const box = $('tuning-body');
  box.replaceChildren(el('div', { class: 'subtle', style: 'padding:20px', text: 'Loading tuning…' }));
  try {
    const [offer, combat, audio, attrs, econ, dbg] = await Promise.all([
      api('/api/offer-rarity'), api('/api/combat-tuning'), api('/api/audio-tuning'),
      api('/api/game-attributes'), api('/api/economy'), api('/api/debug-mode')]);
    const oc = offerRarityDefaults();
    const c = offer.config || {};
    Object.assign(oc.piece, c.piece_rarity || {});
    if (Number.isFinite(c.element_rarity)) oc.element = c.element_rarity;
    Object.assign(oc.count, c.count_multiplier || {});
    const dodge = Object.assign(dodgeDefaults(), (combat.config && combat.config.dodge) || {});
    const crit = Object.assign(critDefaults(), (combat.config && combat.config.crit) || {});
    const aud = Object.assign(audioDefaults(), audio.config || {});
    const ga = Object.assign(gameAttrDefaults(), attrs.config || {});
    const eco = economyDefaults();
    if (econ.config) {
      Object.assign(eco.initial, econ.config.initial || {});
      Object.assign(eco.debug, econ.config.debug || {});
    }
    const SECTIONS = [
      { key: 'offer', label: '⚖ Offer rarity', build: () => offerRaritySection(oc, offer.pool || []) },
      { key: 'economy', label: '💰 Economy', build: () => economySection(eco, ga) },
      { key: 'dodge', label: '⚡ Dodge', build: () => dodgeSection(dodge) },
      { key: 'crit', label: '💥 Crit', build: () => critSection(crit) },
      { key: 'audio', label: '🔊 Audio', build: () => audioSection(aud) },
      { key: 'attrs', label: '👑 Game attributes', build: () => gameAttributesSection(ga) },
    ];
    const bar = el('div', { id: 'tuning-tabs' });
    const content = el('div');
    const show = key => {
      state.tuningTab = key;
      bar.replaceChildren(...SECTIONS.map(s => el('button', {
        class: s.key === key ? 'active' : '', text: s.label, onclick: () => show(s.key) })));
      content.replaceChildren(SECTIONS.find(s => s.key === key).build());
    };
    // The debug-mode handle: maps to the LOCAL debug.json at the game root (git-ignored,
    // per-machine; the game treats an absent file as debug ON). Saves immediately on flip,
    // creating the file if it doesn't exist yet.
    const dbgToggle = el('label', { class: 'check', id: 'debug-mode-toggle',
      title: 'Whether the game launches in DEBUG MODE — writes debug.json at the project root (git-ignored, '
        + 'per-machine; absent = debug ON). Debug mode gates the debug economy bag and the in-game debug '
        + 'buttons (Debug Items, DSFX/DVFX, end-combat ✕). Saves immediately; restart the game to apply.' },
      el('input', { type: 'checkbox', checked: dbg.enabled, onchange: async e => {
        try {
          const r = await api('/api/debug-mode', { enabled: e.target.checked });
          toast('Debug mode ' + (r.enabled ? 'ON' : 'OFF') + ' — saved to debug.json; restart the game to apply', 'ok');
        } catch (err) {
          e.target.checked = !e.target.checked;
          toast('Save failed: ' + err.message, 'err');
        }
      } }),
      ' 🐞 Debug mode');
    box.replaceChildren(
      el('div', { style: 'display:flex;align-items:center;gap:18px' },
        el('div', { class: 'hint', style: 'flex:1',
          text: 'Every global tuning knob in one place. Each section saves to its own game data file — restart the game to apply.' }),
        dbgToggle),
      bar, content);
    show(SECTIONS.some(s => s.key === state.tuningTab) ? state.tuningTab : 'offer');
  } catch (err) {
    box.replaceChildren(el('div', { class: 'subtle', style: 'padding:20px', text: 'Failed to load tuning: ' + err.message }));
  }
}

// The bulk entry point: confirm + pick adherence, then start the server-side job.
function openInferBatchModal(file) {
  const cfg = { adherence: kinDefault(), overwrite: false };
  $('modal-root').replaceChildren(el('div', { class: 'modal', style: 'width:620px' },
    el('h2', {}, '✨ Infer art recipes — ', el('span', { class: 'subtle', text: file })),
    el('div', { class: 'hint', text: 'One LLM pass per card; each result persists onto its entry as it lands '
      + '(revertible per entry). By default cards that already have a recipe are skipped.' }),
    el('div', { class: 'frow', style: 'margin:10px 0' },
      fld('What carries over from each card\'s anchor image',
        selectInput(cfg, 'adherence', KIN_MODES, () => {}),
        'anchor source = the kin bar setting (current art / canonical / custom) — remembered as the default')),
    el('div', { class: 'fld', style: 'margin:6px 0' },
      checkInput(cfg, 'overwrite', () => {}, 'Overwrite existing recipes (re-infer cards that already have one)')),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Cancel', onclick: () => $('modal-root').replaceChildren() }),
      el('button', { class: 'primary', text: '✨ Run', onclick: async () => {
        $('modal-root').replaceChildren();
        try {
          state.settings.kinAdherence = cfg.adherence;
          api('/api/settings', { kinAdherence: cfg.adherence }).catch(() => {});
          const out = await api('/api/art/infer-recipes', { type: 'card', file, adherence: cfg.adherence, overwrite: cfg.overwrite });
          attachInferPoll(file, out.jobId);
          renderItemList();
        } catch (err) { toast('Inference failed: ' + err.message, 'err'); }
      } }))));
}

// ── ⛓ Quick Flow: the appointed flow, one click per card or per file ─────────
function quickFlowSummary(qf) {
  if (!qf || !Array.isArray(qf.steps)) return null;
  const anchor = { base: 'canonical', recipe: 'custom' }[qf.anchor] || qf.anchor || 'custom';
  return qf.steps.map(st => `${(state.artModels[st.model] || { label: st.model }).label}×${st.samples}`
    + (st.denoise ? `@${st.denoise}` : '') + (st.turbo ? '⚡' : '')).join(' → ')
    + ` · anchor: ${anchor}${anchor === 'none' ? ' (step 1 from scratch!)' : ''}`;
}

function attachFlowBatchPoll(file, jobId) {
  if (!state.flowBatchRuns) state.flowBatchRuns = {};
  if (state.flowBatchRuns[file] && state.flowBatchRuns[file].jobId === jobId) return;
  state.flowBatchRuns[file] = { jobId, done: 0, total: 0, phase: '' };
  const poll = async () => {
    const run = state.flowBatchRuns && state.flowBatchRuns[file];
    if (!run || run.jobId !== jobId) return;
    try {
      const j = await api('/api/art/flow-batch-job?id=' + jobId);
      run.done = j.done; run.total = j.total; run.phase = j.phase; run.currentId = j.currentId;
      run.snapshot = j;
      if (run.onUpdate) run.onUpdate(j);   // the live monitor, if open
      if (j.status === 'running' || j.status === 'queued') {   // 'queued' = waiting behind the queue
        renderItemList();
        setTimeout(poll, 2000);
        return;
      }
      delete state.flowBatchRuns[file];
      const picked = (j.results || []).filter(r => r.picked).length;
      const skipped = (j.results || []).filter(r => r.skipped).length;
      const failed = (j.results || []).filter(r => r.error);
      toast(`${file}: quick flow ${j.status === 'stopped' ? 'stopped — ' : ''}${picked} cards got art `
        + `(picked at random from the last step) in ${j.elapsed}s`
        + (skipped ? `, ${skipped} skipped (no recipe)` : '')
        + (failed.length ? ` — ${failed.length} failed (${failed[0].id}: ${failed[0].error})` : ''),
        failed.length ? 'err' : 'ok');
      await refreshState(true);
      if (state.mode === 'game' && state.currentId && !state.dirty && state.gameFile === file)
        openGameItem(state.currentId);
      else if (state.mode === 'game' && state.currentId) renderSidePanels();
    } catch (e) { setTimeout(poll, 4000); }
  };
  poll();
}

// The live monitor: current card, per-image progress, candidates as they land,
// finished cards with their randomly picked art, stop button. Redrawn on every poll.
function openFlowBatchMonitor(file) {
  const body = el('div');
  const stopBtn = el('button', { class: 'ghost', text: '✕ Stop',
    title: 'Stop now — aborts the in-flight image, keeps everything already finished',
    onclick: async () => {
      const r0 = state.flowBatchRuns && state.flowBatchRuns[file];
      if (!r0) return;
      stopBtn.disabled = true;
      try {
        await api('/api/art/flow-batch-stop', { id: r0.jobId });
        toast('Stopping…', 'ok');
      } catch (e) { toast(e.message, 'err'); }
    } });
  const redraw = j => {
    if (!document.body.contains(body)) return;
    body.replaceChildren();
    const running = j.status === 'running' || j.status === 'queued';
    stopBtn.disabled = !running;
    if (j.status === 'queued') {
      body.append(el('div', { class: 'art-status', text: 'Queued — waiting for the current job to finish…' }));
    } else if (running && j.phase === 'recipes') {
      body.append(el('div', { class: 'art-status',
        text: `Filling recipes — ${j.done}/${j.total}${j.currentId ? ' (' + j.currentId + ')' : ''}… (${j.elapsed}s)` }));
    } else if (running) {
      const cf = j.currentFlow;
      body.append(el('div', { class: 'art-status',
        text: `Card ${Math.min(j.done + 1, j.total)}/${j.total} — ${j.currentId || '…'}`
          + (cf ? ` · step ${cf.stepNow}/${cf.stepCount}, image ${Math.min(cf.done + 1, cf.total)}/${cf.total}` : '')
          + ` (${j.elapsed}s)` }));
      if (cf && cf.nodes && cf.nodes.length) {
        body.append(el('div', { class: 'lab subtle', style: 'margin-top:8px', text: `Landing for ${j.currentId}:` }));
        const rowEl = el('div', { style: 'display:flex; flex-wrap:wrap; gap:8px' });
        for (const nd of cf.nodes) {
          const src = `/flowart/card/${j.currentId}/${nd.file}?v=${nd.seed}`;   // repeated filenames → cache-bust
          rowEl.append(el('img', { src, loading: 'lazy',
            style: 'width:132px; height:auto; border-radius:6px; cursor:zoom-in',
            title: `step ${nd.step} · seed ${nd.seed}`,
            onclick: () => openLightbox(src, `#${nd.n} · step ${nd.step} · seed ${nd.seed}`) }));
        }
        body.append(rowEl);
      }
    } else {
      body.append(el('div', { class: j.status === 'error' ? 'art-status err' : 'art-status',
        text: j.status === 'error' ? 'Failed: ' + j.error
          : j.status === 'stopped' ? `Stopped after ${j.elapsed}s.` : `Done in ${j.elapsed}s.` }));
    }
    const done = (j.results || []).filter(r => r.picked);
    if (done.length) {
      body.append(el('div', { class: 'lab subtle', style: 'margin-top:10px',
        text: 'Completed — the randomly picked art (swap any via the card\'s 🗂 pool / ⛓ gallery):' }));
      const rowEl = el('div', { style: 'display:flex; flex-wrap:wrap; gap:8px' });
      for (const r of done) {
        const src = `/flowart/card/${r.id}/${r.picked}?v=${r.seed}`;   // repeated filenames → cache-bust
        rowEl.append(el('div', { style: 'width:132px' },
          el('img', { src, loading: 'lazy', style: 'width:132px; height:auto; border-radius:6px; cursor:zoom-in',
            onclick: () => openLightbox(src, `${r.id} · seed ${r.seed}`) }),
          el('div', { class: 'subtle', style: 'font-size:11px', text: r.id })));
      }
      body.append(rowEl);
    }
    const bad = (j.results || []).filter(r => r.error || r.skipped || r.stopped);
    if (bad.length) {
      body.append(el('div', { class: 'subtle', style: 'margin-top:8px; font-size:12px',
        text: bad.map(r => `${r.id}: ${r.error || (r.stopped ? 'stopped' : 'skipped — no recipe')}`).join(' · ') }));
    }
  };
  $('modal-root').replaceChildren(el('div', { class: 'modal', style: 'width:880px; max-height:86vh; overflow-y:auto' },
    el('h2', {}, '⛓ Quick Flow — ', el('span', { class: 'subtle', text: file })),
    body,
    el('div', { class: 'modal-actions' },
      stopBtn,
      el('button', { class: 'ghost', text: 'Close (keeps running)', onclick: () => $('modal-root').replaceChildren() }))));
  const run = state.flowBatchRuns && state.flowBatchRuns[file];
  if (run) {
    run.onUpdate = redraw;
    if (run.snapshot) redraw(run.snapshot);
    else body.append(el('div', { class: 'art-status', text: 'Starting…' }));
  } else {
    body.append(el('div', { class: 'subtle', text: 'No quick flow running for this file right now.' }));
  }
}

// Step-1 anchor policies for Quick Flow runs — what each card's tree grows from.
const QF_ANCHOR_MODES = [
  { value: 'current', label: 'Current art — each card\'s own working art (none → from scratch)' },
  { value: 'canonical', label: 'Canonical — each card\'s appointed canonical concept ref (refuses if unappointed)' },
  { value: 'custom', label: 'Custom — each card\'s stored recipe reference (none → from scratch)' },
  { value: 'none', label: 'None — every card starts from scratch (step 1 is pure text-to-image)' },
];

// The bulk engagement: eligibility counts, the fill-missing-recipes offer, then run.
function openQuickFlowBatchModal(file, entries) {
  const qf = state.settings.quickFlow;
  const withRecipe = entries.filter(g => g.recipe).length;
  const missing = entries.length - withRecipe;
  // legacy stored policy names from before the canonical system
  const qfAnchor = { base: 'canonical', recipe: 'custom' }[qf && qf.anchor] || (qf && qf.anchor) || 'custom';
  const cfg = { fill: missing > 0, adherence: kinDefault(), anchor: qfAnchor };
  const fillRow = el('div');
  const renderFill = () => {
    // filter nulls: native replaceChildren coerces a null arg to the string "null"
    fillRow.replaceChildren(...[
      missing > 0 ? el('div', { class: 'fld' },
        checkInput(cfg, 'fill', renderFill, `Fill recipes first for the ${missing} card${missing === 1 ? '' : 's'} without one (✨ kin)`)) : null,
      (missing > 0 && cfg.fill) ? el('div', { class: 'frow' },
        fld('What carries over from each card\'s anchor image',
          selectInput(cfg, 'adherence', KIN_MODES, () => {}))) : null,
    ].filter(Boolean));
  };
  renderFill();
  $('modal-root').replaceChildren(el('div', { class: 'modal', style: 'width:640px' },
    el('h2', {}, '⛓ Quick Flow — ', el('span', { class: 'subtle', text: file })),
    qf ? el('div', { class: 'hint', text: quickFlowSummary(qf) })
       : el('div', { class: 'hint', text: 'No Quick Flow appointed yet — open ⛓ Flow… on any card and press ★ Quick Flow.' }),
    el('div', { class: 'subtle', style: 'margin:8px 0', text:
      `${withRecipe} card${withRecipe === 1 ? ' has' : 's have'} a recipe prompt and will flow`
      + (missing ? `; ${missing} lack${missing === 1 ? 's' : ''} one` + (cfg.fill ? '' : ' and will be skipped') : '') + '.' }),
    qf ? el('div', { class: 'frow', style: 'margin:8px 0' },
      fld('Step-1 anchor — the image each card\'s tree grows from (img2img input)',
        selectInput(cfg, 'anchor', QF_ANCHOR_MODES, () => {}),
        'saved onto the Quick Flow appointment — the per-card ⛓ buttons use it too')) : null,
    fillRow,
    el('div', { class: 'hint', text: 'Each card runs the appointed flow; ONE image from the last step is picked at '
      + 'random as its art. Everything lands in the card\'s 🗂 pool and ⛓ gallery, so any pick can be swapped after.' }),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Cancel', onclick: () => $('modal-root').replaceChildren() }),
      el('button', { class: 'primary', text: '⛓ Run', disabled: !qf, onclick: async () => {
        $('modal-root').replaceChildren();
        try {
          if (cfg.fill) {
            state.settings.kinAdherence = cfg.adherence;
            api('/api/settings', { kinAdherence: cfg.adherence }).catch(() => {});
          }
          // the anchor choice persists onto the appointment BEFORE engaging, so this run
          // (the server reads settings.quickFlow) and every per-card ⛓ click follow it
          if (qf && cfg.anchor !== qf.anchor) {
            const qf2 = Object.assign({}, qf, { anchor: cfg.anchor });
            await api('/api/settings', { quickFlow: qf2 });
            state.settings.quickFlow = qf2;
          }
          const out = await api('/api/art/flow-batch', { type: 'card', file, fill: cfg.fill, adherence: cfg.adherence });
          attachFlowBatchPoll(file, out.jobId);
          kickQueue();
          renderItemList();
          openFlowBatchMonitor(file);
        } catch (err) { toast('Quick flow failed: ' + err.message, 'err'); }
      } }))));
}

// ── ✨ batch-inference progress: poll a server job, paint the tree as items land ──
function attachInferPoll(file, jobId) {
  if (!state.inferRuns) state.inferRuns = {};
  if (state.inferRuns[file] && state.inferRuns[file].jobId === jobId) return;   // already attached
  state.inferRuns[file] = { jobId, done: 0, total: 0, doneIds: new Set() };
  const poll = async () => {
    const run = state.inferRuns && state.inferRuns[file];
    if (!run || run.jobId !== jobId) return;   // superseded
    try {
      const j = await api('/api/art/infer-job?id=' + jobId);
      run.done = j.done;
      run.total = j.total;
      for (const r of j.results || []) if (r.prompt || r.skipped) run.doneIds.add(r.id);
      if (j.status === 'running' || j.status === 'queued') {   // 'queued' = waiting behind the queue
        renderItemList();
        setTimeout(poll, 2500);
        return;
      }
      delete state.inferRuns[file];
      const made = (j.results || []).filter(r => r.prompt).length;
      const skipped = (j.results || []).filter(r => r.skipped).length;
      const failed = (j.results || []).filter(r => r.error);
      if (j.status === 'error') toast(`${file}: inference job failed — ${j.error}`, 'err');
      else toast(`${file}: ${made} recipes inferred in ${j.elapsed}s`
        + (skipped ? `, ${skipped} already had one` : '')
        + (failed.length ? ` — ${failed.length} failed (${failed[0].id}: ${failed[0].error})` : ''),
        failed.length ? 'err' : 'ok');
      await refreshState(true);
      // the open card may have just received its recipe — reload it so the art panel
      // shows it (only when there's nothing unsaved to lose)
      if (state.mode === 'game' && state.currentId && !state.dirty && state.gameFile === file)
        openGameItem(state.currentId);
      else if (state.mode === 'game' && state.currentId) renderSidePanels();
    } catch (e) { setTimeout(poll, 4000); }   // transient — keep polling
  };
  poll();
}

// ── sidebar ──────────────────────────────────────────────────────────────────
const TAB_ORDER = ['card', 'relic', 'status', 'ability', 'charm', 'upgrade', 'encounter', 'nodeweights', 'sound', 'vfx', 'render_filter', 'tuning'];
const TAB_LABELS = { card: '🃏 Cards', relic: '🏺 Relics', status: '☠ Statuses', ability: '✨ Abilities',
  charm: '🔮 Charms', upgrade: '🌳 Upgrades', encounter: '⚔ Encounters', nodeweights: '🗺 Map Nodes',
  sound: '🔊 Sounds', vfx: '🎇 VFX', render_filter: '🔆 Filters', tuning: '🎛 Tuning' };

// The ⚔ Encounters tab is the ENEMY HUB: tribes + enemy units (by tribe) + encounter
// templates share its sidebar. Selecting a tribe or an enemy unit flips state.currentType
// under the hood (the editor machinery is type-keyed), so the hub flag keeps the ⚔ tab
// highlighted and the hub sidebar rendered while any of its entries is open.
function inEnemyHub() {
  return state.enemyHub && ['encounter', 'tribe', 'card'].includes(state.currentType);
}

function renderTabs() {
  const tabs = $('type-tabs');
  tabs.replaceChildren();
  const active = inEnemyHub() || state.currentType === 'tribe' ? 'encounter' : state.currentType;
  for (const t of TAB_ORDER) {
    tabs.append(el('button', {
      class: active === t ? 'active' : '',
      text: TAB_LABELS[t] || t,
      onclick: () => { if (!confirmDiscard()) return; state.currentType = t; state.enemyHub = t === 'encounter'; state.currentId = null; state.draft = null; renderTabs(); renderItemList(); renderEditor(); },
    }));
  }
}

// ── composition filters (cards only): the Pieces and Elements realms ─────────
// Each realm filters INDEPENDENTLY: a matching mode plus a chip selection.
//   any   — neutral, the realm doesn't filter at all
//   has   — inclusive: the card must CONTAIN every selected component (others allowed)
//   only  — exclusive: the card may contain ONLY selected components; cards with
//           nothing in this realm (e.g. pure spells for Pieces) are hidden
//   exact — has all selected components and nothing else ("the pure pawn cards")
const COMP_REALMS = {
  piece: { label: 'Pieces', field: 'chess_pieces',
    icons: { pawn: '♟', knight: '♞', bishop: '♝', rook: '♜', queen: '♛', king: '♚' },
    vocab: () => (state.vocab && state.vocab.pieces) || [] },
  element: { label: 'Elements', field: 'elements',
    icons: { fire: '🔥', water: '💧', air: '🌪', earth: '⛰', darkness: '🌑', light: '☀' },
    vocab: () => (state.vocab && state.vocab.elements) || [] },
};
const COMP_MODES = [
  { value: 'any', label: 'any', title: 'Neutral — this realm does not filter' },
  { value: 'has', label: 'has', title: 'Inclusive — show cards that CONTAIN every selected component (other components allowed)' },
  { value: 'only', label: 'only', title: 'Exclusive — show cards built ONLY from selected components (cards with nothing in this realm are hidden)' },
  { value: 'exact', label: 'exact', title: 'Exactly — show cards with all selected components and nothing else' },
];
const COMP_COUNTS = [0, 1, 2];   // per-realm component count (duplicates counted; realm max is 2)
function compFilter(realm) {
  if (!state.compFilter) state.compFilter = {};
  if (!state.compFilter[realm]) state.compFilter[realm] = { mode: 'any', sel: {}, counts: {} };
  if (!state.compFilter[realm].counts) state.compFilter[realm].counts = {};
  return state.compFilter[realm];
}
function realmCountsOn(f) { return COMP_COUNTS.filter(n => f.counts[n]); }
function compFilterActive() {
  return Object.keys(COMP_REALMS).some(r => {
    const f = compFilter(r);
    return f.mode !== 'any' || realmCountsOn(f).length;
  });
}
function realmPasses(realm, g) {
  const f = compFilter(realm);
  const comps = g[COMP_REALMS[realm].field] || [];
  // count gate: the realm's REAL component count, duplicates counted (air_air_pawn_pawn
  // has 2 elements) — this is what separates air_pawn from its doubled variations
  const counts = realmCountsOn(f);
  if (counts.length && !counts.includes(comps.length)) return false;
  if (f.mode === 'any') return true;
  const sel = COMP_REALMS[realm].vocab().filter(v => f.sel[v]);
  const have = [...new Set(comps)];   // mode matching stays set-wise; the count gate handles multiplicity
  if (f.mode === 'has') return sel.every(s => have.includes(s));
  if (f.mode === 'only') return have.length > 0 && have.every(c => sel.includes(c));
  return sel.length === have.length && sel.every(s => have.includes(s));   // exact
}
function cardPassesCompFilter(g) { return realmPasses('piece', g) && realmPasses('element', g); }

function renderCompFilterBar() {
  const realmRow = realm => {
    const meta = COMP_REALMS[realm];
    const f = compFilter(realm);
    const setSel = (vals, on) => { for (const v of vals) f.sel[v] = on; renderItemList(); };
    return el('div', { class: 'comp-realm' + (f.mode === 'any' && !realmCountsOn(f).length ? ' idle' : '') },
      el('span', { class: 'lab', text: meta.label }),
      el('span', { class: 'comp-mode' }, ...COMP_MODES.map(m => el('button', {
        class: m.value === f.mode ? 'active' : '', text: m.label, title: m.title,
        onclick: () => { f.mode = m.value; renderItemList(); },
      }))),
      el('span', { class: 'comp-mode comp-counts', title: 'Component COUNT in this realm (duplicates counted: air_air = 2). '
        + 'Select one or more counts to require; none selected = any count.' },
        ...COMP_COUNTS.map(n => el('button', {
          class: f.counts[n] ? 'active' : '', text: n + '',
          onclick: () => { f.counts[n] = !f.counts[n]; renderItemList(); },
        }))),
      ...meta.vocab().map(v => el('button', {
        class: 'comp-chip' + (f.sel[v] ? ' on' : ''),
        title: (f.sel[v] ? 'Deselect ' : 'Select ') + v,
        onclick: () => setSel([v], !f.sel[v]),
      }, el('span', { text: (meta.icons[v] || '') + ' ' + v }))),
      el('button', { class: 'ghost tiny', text: 'all', title: 'Select every ' + meta.label.toLowerCase() + ' chip', onclick: () => setSel(meta.vocab(), true) }),
      el('button', { class: 'ghost tiny', text: 'none', title: 'Clear the ' + meta.label.toLowerCase() + ' selection', onclick: () => setSel(meta.vocab(), false) }));
  };
  return el('div', { class: 'comp-filter-bar' }, realmRow('piece'), realmRow('element'));
}

// ── the enemy hub sidebar (⚔ Encounters tab): tribes → enemy units by tribe → templates ──
function renderEnemyHubList() {
  state.enemyHub = true;
  $('item-list-title').textContent = 'Enemy Hub';
  $('gen-set-btn').hidden = true;
  $('bulk-edit-btn').hidden = true;
  const list = $('item-list');
  list.replaceChildren();
  const search = el('input', {
    type: 'text', placeholder: 'filter…', value: state.gameFilter,
    style: 'margin:0 4px 8px; width:calc(100% - 8px)',
    oninput: e => { state.gameFilter = e.target.value; renderItemList(); },
  });
  list.append(search);
  const q = state.gameFilter.trim().toLowerCase();
  const match = g => !q || g.id.includes(q) || (g.name || '').toLowerCase().includes(q);
  if (!state.gameTree.hub) state.gameTree.hub = {};
  const expand = state.gameTree.hub;
  const open = (type, id) => { if (!confirmDiscard()) return; state.currentType = type; openGameItem(id); renderTabs(); };
  const fresh = type => { if (!confirmDiscard()) return; state.currentType = type; newItem(); renderTabs(); };
  const isActive = (type, id) => state.mode === 'game' && state.currentType === type && state.currentId === id;
  const section = (key, title, count, addType) => el('div', {
    class: 'tree-file' + (expand[key] !== false || q ? ' open' : ''),
    onclick: () => { expand[key] = expand[key] === false; renderItemList(); },
  },
    el('span', { class: 'tree-arrow', text: (expand[key] !== false || q) ? '▾' : '▸' }),
    el('span', { class: 'tree-file-name', text: title }),
    el('span', { class: 'subtle', text: count + '' }),
    addType ? el('button', { class: 'ghost tiny', text: '＋', title: 'New ' + addType,
      onclick: e => { e.stopPropagation(); fresh(addType); } }) : null);
  const row = (type, g, extraPills) => el('div', {
    class: 'item-row tree-leaf' + (isActive(type, g.id) ? ' active' : '') + (g.parked ? ' parked' : ''),
    onclick: () => open(type, g.id),
  },
    g.art ? el('img', { class: 'thumb', loading: 'lazy', src: '/gameart/' + g.art }) : null,
    el('div', { class: 'item-name' }, el('div', { text: g.name }), el('div', { class: 'item-id', text: g.id })),
    g.edited ? el('span', { class: 'pill installed', text: 'edited' }) : null,
    ...(extraPills || []));

  // ── Tribes ──
  const tribes = (state.game.tribe || []).slice().sort((a, b) => a.id.localeCompare(b.id));
  const tribeName = id => { const t = tribes.find(x => x.id === id); return t ? t.name : id; };
  const shownTribes = tribes.filter(match);
  list.append(section('tribes', '🧬 Tribes', tribes.length, 'tribe'));
  if (expand.tribes !== false || q) for (const t of shownTribes) list.append(row('tribe', t));

  // ── Enemy units, grouped by tribe ──
  const enemies = (state.game.card || []).filter(g => g.enemy_only);
  const byTribe = new Map();
  for (const g of enemies.filter(match)) {
    const k = g.tribe || '(no tribe)';
    if (!byTribe.has(k)) byTribe.set(k, []);
    byTribe.get(k).push(g);
  }
  list.append(section('enemies', '👹 Enemy Units', enemies.length, 'card'));
  if (expand.enemies !== false || q) {
    for (const k of [...byTribe.keys()].sort()) {
      const units = byTribe.get(k).sort((a, b) => a.id.localeCompare(b.id));
      const ek = 'et:' + k;
      list.append(el('div', {
        class: 'tree-file' + (expand[ek] || q ? ' open' : ''), style: 'padding-left:18px',
        onclick: () => { expand[ek] = !expand[ek]; renderItemList(); },
      },
        el('span', { class: 'tree-arrow', text: (expand[ek] || q) ? '▾' : '▸' }),
        el('span', { class: 'tree-file-name', text: k === '(no tribe)' ? k : tribeName(k) }),
        el('span', { class: 'subtle', text: units.length + '' })));
      if (expand[ek] || q) for (const g of units)
        list.append(row('card', g, [g.recipe ? el('span', { class: 'subtle', text: '✨', title: 'has an art recipe' }) : null]));
    }
  }

  // ── Encounter templates, grouped by file (as ever) ──
  const encounters = (state.game.encounter || []).slice().sort((a, b) => a.id.localeCompare(b.id));
  const byFile = new Map();
  for (const g of encounters.filter(match)) {
    if (!byFile.has(g.file)) byFile.set(g.file, []);
    byFile.get(g.file).push(g);
  }
  list.append(section('encounters', '⚔ Encounters', encounters.length, 'encounter'));
  if (expand.encounters !== false || q) {
    for (const file of [...byFile.keys()].sort()) {
      const entries = byFile.get(file);
      const fk = 'ef:' + file;
      const holdsCurrent = entries.some(g => isActive('encounter', g.id));
      const fOpen = q || (expand[fk] != null ? expand[fk] : holdsCurrent);
      list.append(el('div', {
        class: 'tree-file' + (fOpen ? ' open' : ''), style: 'padding-left:18px',
        onclick: () => { expand[fk] = !fOpen; renderItemList(); },
      },
        el('span', { class: 'tree-arrow', text: fOpen ? '▾' : '▸' }),
        el('span', { class: 'tree-file-name', text: file }),
        el('span', { class: 'subtle', text: entries.length + '' })));
      if (fOpen) for (const g of entries) list.append(row('encounter', g));
    }
  }
  if (q) { search.focus(); const v = search.value; search.value = ''; search.value = v; }
}

function renderItemList() {
  // The Tuning tab is a single full-width view of global config — no item list at all.
  $('sidebar').hidden = state.currentType === 'tuning';
  if (state.currentType === 'tuning') return;
  // The ⚔ Encounters tab renders the enemy hub instead of a single-type list.
  if (state.currentType === 'encounter' || state.currentType === 'tribe' || inEnemyHub()) {
    renderEnemyHubList();
    return;
  }
  $('item-list-title').textContent = state.types[state.currentType] ? state.types[state.currentType].label + 's' : '';
  $('gen-set-btn').hidden = state.currentType !== 'card';
  $('bulk-edit-btn').hidden = state.currentType !== 'card';
  const list = $('item-list');
  list.replaceChildren();
  // ── THE list: the game's data files (files → entries) — nothing else exists ──
  const gameItems = (state.game[state.currentType] || []).slice()
    .sort((a, b) => a.id.localeCompare(b.id));
  if (!gameItems.length) { list.append(el('div', { class: 'subtle', style: 'padding:10px', text: 'No ' + state.types[state.currentType].label.toLowerCase() + 's yet — press + New.' })); return; }
  const search = el('input', {
    type: 'text', placeholder: 'filter…', value: state.gameFilter,
    style: 'margin:0 4px 8px; width:calc(100% - 8px)',
    oninput: e => { state.gameFilter = e.target.value; renderItemList(); },
  });
  list.append(search);
  if (state.currentType === 'card') list.append(renderCompFilterBar());
  const q = state.gameFilter.trim().toLowerCase();
  let filtered = q ? gameItems.filter(g => g.id.includes(q) || (g.name || '').toLowerCase().includes(q)) : gameItems;
  // enemy units live in the ⚔ Encounters tab's hub (grouped by tribe), not the main card list
  if (state.currentType === 'card') filtered = filtered.filter(g => !g.enemy_only);
  const compActive = state.currentType === 'card' && compFilterActive();
  if (compActive) filtered = filtered.filter(cardPassesCompFilter);
  // the ≡ Bulk… button acts on exactly this filtered set — remember its ids + count
  if (state.currentType === 'card') {
    state.bulkIds = filtered.map(g => g.id);
    const bb = $('bulk-edit-btn');
    bb.textContent = `≡ Bulk (${filtered.length})`;
    bb.disabled = !filtered.length;
  }
  if (!filtered.length) list.append(el('div', { class: 'subtle', style: 'padding:10px', text: 'Nothing matches the filters.' }));

  // group by file
  const byFile = new Map();
  for (const g of filtered) {
    if (!byFile.has(g.file)) byFile.set(g.file, []);
    byFile.get(g.file).push(g);
  }
  if (!state.gameTree[state.currentType]) state.gameTree[state.currentType] = {};
  const expandState = state.gameTree[state.currentType];

  for (const file of [...byFile.keys()].sort()) {
    const entries = byFile.get(file);
    // a filter match, or the open item's file, force the branch open
    const holdsCurrent = state.mode === 'game' && entries.some(g => g.id === state.currentId);
    const expanded = (q || compActive) ? true : (expandState[file] != null ? expandState[file] : holdsCurrent);
    const editedCount = entries.filter(g => g.edited).length;
    list.append(el('div', {
      class: 'tree-file' + (expanded ? ' open' : ''),
      onclick: () => { expandState[file] = !expanded; renderItemList(); },
    },
      el('span', { class: 'tree-arrow', text: expanded ? '▾' : '▸' }),
      el('span', { class: 'tree-file-name', text: file }),
      editedCount ? el('span', { class: 'pill installed', text: editedCount + ' edited' }) : null,
      el('span', { class: 'subtle', text: entries.length + '' }),
      (state.inferRuns && state.inferRuns[file])
        ? el('span', { class: 'pill installed',
            text: `✨ ${state.inferRuns[file].done}/${state.inferRuns[file].total}…`,
            title: 'batch inference running server-side — recipes land on entries as each card completes; safe to browse meanwhile' })
        : (state.currentType === 'card' ? el('button', { class: 'ghost tiny', text: '✨',
            title: 'Infer art recipes for every card in this file that lacks one — pick the adherence '
              + '(what carries over from each card\'s anchor image) and run. Server-side; progress shows here.',
            onclick: e => {
              e.stopPropagation();
              openInferBatchModal(file);
            } }) : null),
      (state.flowBatchRuns && state.flowBatchRuns[file])
        ? el('span', { class: 'pill installed',
            text: `⛓ ${state.flowBatchRuns[file].phase === 'recipes' ? '✨' : ''}${state.flowBatchRuns[file].done}/${state.flowBatchRuns[file].total}…`,
            title: 'Quick Flow batch running server-side'
              + (state.flowBatchRuns[file].currentId ? ` — now on ${state.flowBatchRuns[file].currentId}` : '') })
        : (state.currentType === 'card' ? el('button', { class: 'ghost tiny', text: '⛓',
            title: 'Run the appointed Quick Flow on every card in this file that has a recipe prompt '
              + '(offers to fill missing recipes first); one image from the last step is picked at '
              + 'random as each card\'s art',
            onclick: e => {
              e.stopPropagation();
              openQuickFlowBatchModal(file, entries);
            } }) : null),
    ));
    if (!expanded) continue;
    const run = state.inferRuns && state.inferRuns[file];
    for (const g of entries) {
      // recipe marker: stored on the entry, or landed just now by the running batch
      const hasRecipe = g.recipe || (run && run.doneIds.has(g.id));
      list.append(el('div', {
        class: 'item-row tree-leaf' + (state.mode === 'game' && state.currentId === g.id ? ' active' : '')
          + (g.parked ? ' parked' : ''),
        onclick: () => {
          if (!confirmDiscard()) return;
          openGameItem(g.id);
        },
      },
        g.art ? el('img', { class: 'thumb', loading: 'lazy', src: '/gameart/' + g.art }) : null,
        el('div', { class: 'item-name' }, el('div', { text: g.name }), el('div', { class: 'item-id', text: g.id })),
        g.parked ? el('span', { class: 'pill', text: 'parked', title: 'enabled: false — no live cue site yet; visible backlog, never deleted' }) : null,
        g.edited ? el('span', { class: 'pill installed', text: 'edited' }) : null,
        hasRecipe ? el('span', { class: 'subtle', text: '✨', title: 'has an art recipe (prompt stored on the entry)' }) : null,
        (state.currentType === 'card' && !run) ? el('button', { class: 'ghost tiny', text: '✨',
          title: (hasRecipe ? 'Re-infer THIS card\'s recipe from its family and OVERWRITE the existing one '
                            : 'Infer THIS card\'s art recipe from its family and store it on the entry ')
            + `(adherence: ${kinDefault()} — set the ✨ kin default above the list)`,
          onclick: async e => {
            e.stopPropagation();
            if (hasRecipe && !confirm(`Overwrite the existing art recipe for "${g.id}"?`)) return;
            const btn = e.target;
            btn.disabled = true; btn.textContent = '…';
            try {
              const out = await api('/api/art/infer-recipe',
                { type: 'card', id: g.id, persist: true, adherence: kinDefault() });
              const st = out.stats || {};
              toast(`${g.id}: recipe inferred (${st.prompts || 0} stored prompts, ${st.images || 0} art images, ${Math.round((st.ms || 0) / 1000)}s)`, 'ok');
              await refreshState(true);
              if (state.currentId === g.id && !state.dirty) openGameItem(g.id);
              else if (state.mode === 'game' && state.currentId) renderSidePanels();
            } catch (err) {
              toast(`${g.id}: ${err.message}`, 'err');
              btn.disabled = false; btn.textContent = '✨';
            }
          } }) : null,
        // one-click Quick Flow: recipe-carrying cards only (the recipe prompt IS the flow
        // prompt). Stays available while other flows run — each click queues another; the
        // queue widget monitors them all (so we don't pop a modal per click here).
        (state.currentType === 'card' && hasRecipe && !run) ? el('button', { class: 'ghost tiny', text: '⛓',
          title: `Queue the Quick Flow on THIS card — one image from the last step is picked at random as its art`
            + (state.settings.quickFlow ? ` (${quickFlowSummary(state.settings.quickFlow)})` : ' — none appointed yet'),
          onclick: async e => {
            e.stopPropagation();
            const btn = e.target;
            btn.disabled = true; btn.textContent = '…';
            try {
              const out = await api('/api/art/flow-batch', { type: 'card', ids: [g.id], fill: false });
              attachFlowBatchPoll(g.file, out.jobId);   // completion refreshes the art in place
              kickQueue();
              toast(out.already ? `${g.id}: already queued` : `${g.id}: quick flow queued`, 'ok');
              renderItemList();
            } catch (err) {
              toast(`${g.id}: ${err.message}`, 'err');
              btn.disabled = false; btn.textContent = '⛓';
            }
          } }) : null,
      ));
    }
  }
  if (q) { search.focus(); const v = search.value; search.value = ''; search.value = v; }
}

function confirmDiscard() {
  if (!state.dirty) return true;
  return confirm('You have unsaved changes — discard them?');
}

// ── editor lifecycle ─────────────────────────────────────────────────────────
// ONE lifecycle: every entry lives in a real game data file. Opening reads it there;
// Save writes it back (or appends a new entry to a chosen file); Revert restores the
// snapshot; the Enabled checkbox is the on/off switch the game loaders respect.
async function openGameItem(id) {
  let g;
  try { g = await api(`/api/game/item?type=${state.currentType}&id=${encodeURIComponent(id)}`); }
  catch (e) { toast(e.message, 'err'); return; }
  const ed = EDITORS[state.currentType];
  if (state.advancedOpen) { state.advancedOpen = false; $('modal-root').replaceChildren(); }
  state.mode = 'game';
  state.currentId = id;
  state.isNew = false;
  state.gameFile = g.file;
  state.gameEdited = g.edited;
  state.gameHasArt = !!g.hasArt;
  state.gameArt = g.gameArt || null;
  state.draft = ed.toDraft ? ed.toDraft(g.data) : JSON.parse(JSON.stringify(g.data));
  state.draft.enabled = g.data.enabled !== false;
  state.dirty = false;
  renderItemList(); renderEditor();
}

function newItem() {
  if (!confirmDiscard()) return;
  if (state.advancedOpen) { state.advancedOpen = false; $('modal-root').replaceChildren(); }
  state.mode = 'game';
  state.currentId = null;
  state.isNew = true;
  state.gameFile = null;
  state.gameEdited = false;
  state.gameHasArt = false;
  state.gameArt = null;
  state.draft = EDITORS[state.currentType].newItem();
  state.draft.enabled = true;
  state.dirty = false;
  renderItemList(); renderEditor();
}

function editorCtx() {
  const ws = {};
  for (const t of Object.keys(state.items)) ws[t] = state.items[t];
  return { vocab: state.vocab, workspace: ws, isNew: state.isNew, type: state.currentType };
}

function clientDeployPreview(type, serialized) {
  const strip = o => {
    if (Array.isArray(o)) return o.map(strip);
    if (o && typeof o === 'object') {
      const out = {};
      for (const [k, v] of Object.entries(o)) if (!k.startsWith('_')) out[k] = strip(v);
      return out;
    }
    return o;
  };
  if (type === 'nodeweights') return strip(serialized.bands || []);
  return strip(serialized);
}

function renderEditor() {
  const empty = $('editor-empty'), body = $('editor-body'), tuning = $('tuning-body');
  if (state.currentType === 'tuning') {
    empty.hidden = true; body.hidden = true;
    // only (re)load on entry — background re-renders must not clobber in-progress edits
    if (tuning.hidden) { tuning.hidden = false; renderTuningView(); }
    return;
  }
  tuning.hidden = true;
  if (!state.draft) { empty.hidden = false; body.hidden = true; renderEmptyKinPanel(); return; }
  empty.hidden = true; body.hidden = false;
  const ed = EDITORS[state.currentType];

  $('item-title').textContent = (state.isNew ? 'New ' : '') + ed.label +
    (state.draft.display_name ? ' — ' + state.draft.display_name : state.draft.id ? ' — ' + state.draft.id : '');
  $('dirty-flag').hidden = !state.dirty;
  $('validation-msg').hidden = true;

  const formCol = $('form-col');
  formCol.replaceChildren(ed.form(state.draft, editorCtx(), onDraftChange));
  renderSidePanels();
  refreshInstallBar();
}

function onDraftChange() {
  state.dirty = true;
  $('dirty-flag').hidden = false;
  $('item-title').textContent = (state.isNew ? 'New ' : '') + EDITORS[state.currentType].label +
    (state.draft.display_name ? ' — ' + state.draft.display_name : state.draft.id ? ' — ' + state.draft.id : '');
  renderSidePanels();
}

function renderSidePanels() {
  const ed = EDITORS[state.currentType];
  // summary
  const sum = $('summary-body');
  sum.replaceChildren();
  for (const line of ed.summarize(state.draft)) sum.append(el('div', { class: 'sum-line', text: line }));
  // json
  try {
    const payload = clientDeployPreview(state.currentType, ed.serialize(state.draft));
    $('json-preview').textContent = JSON.stringify(payload, null, 2);
  } catch (e) {
    $('json-preview').textContent = '(serialize error: ' + e.message + ')';
  }
  renderArtPanel();
}

// ── toolbar ──
function refreshInstallBar() {
  const t = state.types[state.currentType];
  const info = $('install-info');
  $('revert-btn').hidden = !state.gameEdited;
  $('delete-btn').hidden = state.isNew;
  $('enabled-check').checked = state.draft ? state.draft.enabled !== false : true;
  const bits = [];
  if (state.isNew) bits.push('New entry — Save adds it to a ' + (t ? t.dataDir : '') + ' file of your choice');
  else bits.push('In <b>' + t.dataDir + '/' + state.gameFile + '</b>');
  if (state.draft && state.draft.enabled === false) bits.push('<span style="color:var(--bad)">disabled — the game skips it</span>');
  if (state.dirty) bits.push('<span style="color:var(--accent)">unsaved changes</span>');
  bits.push('<span class="subtle">the game reads data at startup · new images import when the Godot editor regains focus</span>');
  info.innerHTML = bits.join(' · ');
}

function showValidation(msg, ok) {
  const box = $('validation-msg');
  box.hidden = false;
  box.className = ok ? 'ok' : '';
  box.textContent = msg;
}

// The one save: serialize the editor, carry the enabled flag, write the entry into its
// game file (append for new entries, into a file the user picks).
async function gameSave(quiet) {
  const ed = EDITORS[state.currentType];
  let data;
  try { data = ed.serialize(state.draft); } catch (e) { toast('Cannot serialize: ' + e.message, 'err'); return false; }
  if (state.draft.enabled === false) data.enabled = false;
  // the art panel's recipe persists on the entry (tool.art); other tool.* keys pass through
  const artMeta = state.draft._art ? artMetaFromDraft(state.draft._art)
    : (state.draft.tool && state.draft.tool.art) || null;
  const toolMeta = Object.assign({}, state.draft.tool);
  if (artMeta) toolMeta.art = artMeta; else delete toolMeta.art;
  if (Object.keys(toolMeta).length) data.tool = toolMeta;
  if (!/^[a-z0-9_]+$/.test(data.id || '')) {
    showValidation('id must be lowercase letters, digits and underscores'); return false;
  }
  let file = state.gameFile;
  if (state.isNew) {
    if ((state.game[state.currentType] || []).some(g => g.id === data.id)) {
      showValidation(`"${data.id}" already exists — open it from the list instead.`); return false;
    }
    file = await pickTargetFile(data.id);
    if (!file) return false;
  }
  try {
    const out = await api('/api/game/save', { type: state.currentType, file, data });
    state.currentId = data.id;
    state.isNew = false;
    state.gameFile = out.file.split('/').pop();
    state.gameEdited = true;
    state.dirty = false;
    if (!quiet) toast(`Saved into ${out.file}` + (out.art ? ' (+ art)' : ''), 'ok');
  } catch (e) { showValidation(e.message); return false; }
  await refreshState(true);
  renderItemList();
  renderSidePanels();
  $('dirty-flag').hidden = true;
  return true;
}

// Where should a NEW entry live? An existing file of this type, or a fresh normally-named one.
function pickTargetFile(id) {
  return new Promise(resolve => {
    const files = [...new Set((state.game[state.currentType] || []).map(g => g.file))].sort();
    const cfg = { file: files[0] || '', fresh: files.length ? '' : (id + '.json') };
    const modal = el('div', { class: 'modal' },
      el('h2', { text: 'Which file should this live in?' }),
      files.length ? fld('Existing file', selectInput(cfg, 'file', files, () => { cfg.fresh = ''; renderFresh(); })) : null,
      fld('…or a new file', el('input', { type: 'text', value: cfg.fresh, placeholder: 'e.g. ' + id + '.json',
        oninput: e => { cfg.fresh = e.target.value; } })),
      el('div', { class: 'modal-actions' },
        el('button', { class: 'ghost', text: 'Cancel', onclick: () => { $('modal-root').replaceChildren(); resolve(null); } }),
        el('button', { class: 'primary', text: 'Save here', onclick: () => {
          let f = (cfg.fresh || '').trim() || cfg.file;
          if (f && !f.endsWith('.json')) f += '.json';
          $('modal-root').replaceChildren();
          resolve(f || null);
        } }),
      ));
    function renderFresh() {}
    $('modal-root').replaceChildren(modal);
  });
}

async function gameRevert() {
  if (!confirm(`Revert "${state.currentId}" to how it was before the tool touched it?`)) return;
  try {
    const out = await api('/api/game/restore', { type: state.currentType, id: state.currentId });
    toast('Reverted in ' + out.file, 'ok');
  } catch (e) { toast(e.message, 'err'); return; }
  await refreshState(true);
  const still = (state.game[state.currentType] || []).some(g => g.id === state.currentId);
  if (still) await openGameItem(state.currentId);
  else { state.draft = null; state.currentId = null; renderEditor(); renderItemList(); }
}

async function deleteItem() {
  if (state.isNew) { state.draft = null; renderEditor(); return; }
  if (!confirm(`Remove "${state.currentId}" from ${state.gameFile}?\n(Revert can bring it back until the next change.)`)) return;
  try {
    const out = await api('/api/game/delete-entry', { type: state.currentType, id: state.currentId });
    toast('Removed from ' + out.file + (out.removedFile ? ' (file emptied and deleted)' : ''), 'ok');
  } catch (e) { toast(e.message, 'err'); return; }
  state.currentId = null; state.draft = null; state.dirty = false;
  await refreshState();
}

// ── art panel ────────────────────────────────────────────────────────────────
function artDefaults() {
  const t = state.types[state.currentType];
  // turbo defaults ON (user directive) — it only ever applies to models that support it
  // (Flux 2); the checkbox, the request and the flow steps all gate on supportsTurbo
  return { width: t.artW, height: t.artH, rembg: t.rembg, steps: 20, guidance: 4.0, seed: -1, turbo: true };
}

// ── per-entry art recipe (entry.tool.art) ────────────────────────────────────
// The art panel's live state persists WITH the entry on Save, so the whole
// generation recipe — prompt, model, dims, reference (path/ID), ✨ guidance,
// and the seed/style/prompt that produced the last image (`last`, stamped at
// generation) — travels with the content in its data file. Anything can read
// it back off the JSON (this panel on open, scripts, batch regeneration).
// `touched` gates the write: a panel the user never interacted with stamps
// nothing, so untouched entries stay metadata-free.
function artMetaFromDraft(a) {
  if (!a || !a.touched) return null;
  const m = { model: a.model || 'flux2', width: a.width, height: a.height,
    steps: a.steps, guidance: a.guidance, rembg: !!a.rembg };
  if (a.prompt) m.prompt = a.prompt;
  if (a.negative) m.negative = a.negative;
  if (a.seed != null && a.seed >= 0) m.seed = a.seed;
  if (a.turbo) m.turbo = true;
  if (a.refSource && a.refSource !== 'none') {
    m.ref = { source: a.refSource };
    const p = a.refSource === 'upload' ? a.refUpload : a.refSource === 'game' ? a.refGameArt : null;
    if (p) m.ref.path = p;
    if (a.refSource === 'upload' && a.refUploadLabel) m.ref.name = a.refUploadLabel;
    if (a.refSource === 'game' && a.refGameName) m.ref.name = a.refGameName;
    if (a.refMode) m.ref.mode = a.refMode;
    if (a.denoise != null) m.ref.denoise = a.denoise;
  }
  if (a.llmConcept) m.concept = a.llmConcept;
  if (a.llmRefHint) m.refHint = a.llmRefHint;
  if ((a.llmRefs || []).length) m.llmRefs = a.llmRefs.map(r => ({ name: r.name, art: r.art }));
  if ((a.llmHidden || []).length) m.llmHidden = a.llmHidden.slice();
  if ((a.llmShown || []).length) m.llmShown = a.llmShown.slice();
  if (a.lastGen) m.last = Object.assign({}, a.lastGen);
  return m;
}

function artDraftFromMeta(m) {
  const a = Object.assign(artDefaults(), { prompt: m.prompt || '', touched: true });
  for (const k of ['model', 'width', 'height', 'steps', 'guidance', 'negative']) if (m[k] != null) a[k] = m[k];
  a.seed = m.seed != null ? m.seed : -1;
  a.rembg = !!m.rembg;
  a.turbo = !!m.turbo;
  if (m.ref && m.ref.source) {
    a.refSource = m.ref.source;
    if (m.ref.source === 'upload') { a.refUpload = m.ref.path; a.refUploadLabel = m.ref.name || m.ref.path; }
    if (m.ref.source === 'game') { a.refGameArt = m.ref.path; a.refGameName = m.ref.name || ''; }
    if (m.ref.mode) a.refMode = m.ref.mode;
    if (m.ref.denoise != null) a.denoise = m.ref.denoise;
  }
  if (m.concept) a.llmConcept = m.concept;
  if (m.refHint) a.llmRefHint = m.refHint;
  if (m.llmRefs) a.llmRefs = m.llmRefs.map(r => ({ name: r.name, art: r.art }));
  if (m.llmHidden) a.llmHidden = m.llmHidden.slice();
  if (m.llmShown) a.llmShown = m.llmShown.slice();
  if (m.last) a.lastGen = Object.assign({}, m.last);
  return a;
}

// Mechanical data lines (composition / stat blocks) pollute art concepts — they are
// hidden from the ✨ prompt writer BY DEFAULT (user directive: "pretty much no
// scenario where I would want that"). The advanced checklist can still tick one back
// on for a specific item (a.llmShown); explicit unticks live in a.llmHidden as before.
function llmMechLine(l) {
  return /^Composition: /.test(l)
    || /^Cost \d+ · ATK /.test(l)
    || /^Stats derived from the composition/.test(l);
}
function llmLineVisible(a, l) {
  // HARD RULE: composition/stat lines NEVER reach the ✨ prompt writer — the leak is kept
  // out of the INPUT entirely, so there is nothing to filter out of the output. No per-item
  // opt-in either (the old llmShown escape hatch is gone).
  if (llmMechLine(l)) return false;
  if ((a.llmHidden || []).includes(l)) return false;
  return true;
}

// The item's art-generation draft, defaults applied (shared by both views).
// Seeded from the entry's stored recipe (tool.art) when it has one.
function artDraft() {
  if (!state.draft._art)
    state.draft._art = state.draft.tool && state.draft.tool.art
      ? artDraftFromMeta(state.draft.tool.art)
      : Object.assign(artDefaults(), { prompt: '' });
  const a = state.draft._art;
  if (!a.model || !state.artModels[a.model]) {
    // Krea 2 is the house default — adopt its step/guidance profile along with the pick
    a.model = state.artModels.krea2 ? 'krea2' : 'flux2';
    const m0 = state.artModels[a.model];
    if (m0) { a.steps = m0.steps; a.guidance = m0.guidance; }
  }
  return a;
}

// The compact ("normal") art panel in the editor's side column. All generation controls
// come from buildArtControls / buildArtPreviews, shared with the fullscreen advanced mode.
function renderArtPanel() {
  const panel = $('art-panel');
  panel.replaceChildren(el('h3', {}, 'Art (ComfyUI) ',
    el('button', { class: 'ghost tiny', text: '⛶ Advanced',
      title: 'Fullscreen generator with a reference browser (pull existing card art as input for the image model and the LLM)',
      onclick: openAdvanced })));
  const kin = buildKinSection();
  if (kin) panel.append(kin);
  panel.append(...buildArtControls(renderArtPanel));
  panel.append(...buildArtPreviews(renderArtPanel));
  if (state.advancedOpen) renderAdvanced();
}

// Every generation control (model, prompt, style, references, dims, generate button),
// as an array of nodes. `rerender` = the calling view's own re-render function;
// `advanced` adds the LLM guidance inputs that only the fullscreen view has room for.
function buildArtControls(rerender, advanced) {
  const ed = EDITORS[state.currentType];
  const a = artDraft();
  const mdl = state.artModels[a.model];

  const noChange = () => { a.touched = true; state.dirty = true; $('dirty-flag').hidden = false; };
  // empty prompt = auto-derive from the item's current name/description at generate time
  const promptArea = el('textarea', {
    value: a.prompt || '', rows: 3, placeholder: 'auto: ' + ed.promptFor(state.draft),
    oninput: e => { a.prompt = e.target.value; noChange(); },
  });

  // ── shared STYLE prompt: one global fragment appended to every generation, with presets ──
  const styleArea = el('textarea', {
    value: state.settings.artStyle || '', rows: 2,
    placeholder: 'e.g. cartoon art style, 2d illustration — appended to every prompt',
    oninput: e => { state.settings.artStyle = e.target.value; saveStyleSoon(); },
  });
  const styleRow = el('div', { class: 'frow' },
    el('div', { class: 'fld wide' },
      el('span', { class: 'lab' }, 'Style (shared across ALL generations) ',
        ...presetControls('stylePresets', () => styleArea.value,
          v => { state.settings.artStyle = v; styleArea.value = v; saveStyleSoon(); })),
      styleArea),
  );

  // ── reference image: the item's current art, an uploaded external image, or another
  // card's game art picked in the advanced mode's reference browser ──
  const artAvail = !!state.gameArt || state.gameHasArt;
  const refSrcLabel = state.gameArt ? 'the in-game art' : 'the latest generated image';
  if (a.useRef && !a.refSource) a.refSource = 'current';   // drafts from the checkbox era
  if (!a.refSource || !mdl.supportsRef) a.refSource = mdl.supportsRef ? a.refSource || 'none' : 'none';
  if (a.refSource === 'current' && !artAvail) a.refSource = 'none';   // offering it would only error
  if (a.refSource === 'game' && !a.refGameArt) a.refSource = 'none';
  const refActive = a.refSource !== 'none';
  const refRow = el('div', { class: 'frow' },
    fld('Reference image', mdl.supportsRef
      ? selectInput(a, 'refSource', [
          { value: 'none', label: 'None' },
          artAvail ? { value: 'current', label: `Current art (${refSrcLabel})` } : null,
          a.refGameArt ? { value: 'game', label: `Game art: ${a.refGameName || a.refGameArt}` } : null,
          { value: 'upload', label: 'Uploaded image…' },
        ].filter(Boolean), () => { noChange(); rerender(); })
      : el('span', { class: 'hint', text: `${mdl.label} has no reference path` })),
    a.refSource === 'upload' ? el('div', { class: 'fld' },
      el('span', { class: 'lab', text: a.refUploadLabel ? `Using: ${a.refUploadLabel}` : 'Pick an image file' }),
      el('input', { type: 'file', accept: 'image/*', onchange: async e => {
        const f = e.target.files && e.target.files[0];
        if (!f) return;
        try {
          const dataUrl = await new Promise((ok, bad) => {
            const r = new FileReader();
            r.onload = () => ok(r.result); r.onerror = () => bad(new Error('reading the file failed'));
            r.readAsDataURL(f);
          });
          const out = await api('/api/art/upload-ref', { name: f.name, dataBase64: dataUrl.split(',')[1] });
          a.refUpload = out.name; a.refUploadLabel = f.name;
          noChange(); rerender();
        } catch (err) { toast('Reference upload failed: ' + err.message, 'err'); }
      } })) : null,
  );

  if (mdl.refModes && refActive && !mdl.refModes.some(rm => rm.value === a.refMode)) a.refMode = mdl.refModes[0].value;
  if (mdl.refModes && a.denoise == null) a.denoise = 0.6;
  const refModeRow = (mdl.refModes && refActive) ? el('div', { class: 'frow' },
    fld('Reference mode', selectInput(a, 'refMode', mdl.refModes, () => { noChange(); rerender(); })),
    a.refMode === 'img2img'
      ? fld('Denoise', numInput(a, 'denoise', noChange, { float: true, step: 0.05, min: 0.05, max: 1 }),
            'Lower = closer to the reference; higher = more freedom to restyle')
      : null,
  ) : null;

  // ── LLM visual references attached from the browser: a removable chip strip ──
  const llmStrip = (a.llmRefs && a.llmRefs.length) ? el('div', { class: 'attached-strip' },
    el('span', { class: 'lab', text: 'LLM sees:' }),
    ...a.llmRefs.map(r => el('span', { class: 'chip-ref' }, r.name,
      el('button', { class: 'ghost tiny', text: '✕', title: 'Detach', onclick: () => {
        a.llmRefs = a.llmRefs.filter(x => x.art !== r.art);
        noChange(); rerender();
      } }))),
  ) : null;

  // ── model picker: each entry is a full architecture with its own defaults ──
  const modelRow = el('div', { class: 'frow' },
    fld('Model', selectInput(a, 'model', Object.entries(state.artModels)
      .map(([k, v]) => ({ value: k, label: v.label })), () => {
      // switching models adopts that model's step/guidance profile; turbo defaults ON
      // wherever it's supported (Flux 2), with the matching turbo step count
      const nm = state.artModels[a.model];
      a.turbo = !!nm.supportsTurbo;
      a.steps = a.turbo ? (state.settings.turboSteps || 8) : nm.steps;
      a.guidance = nm.guidance;
      if (!nm.supportsRef) { a.useRef = false; a.refSource = 'none'; }
      noChange(); rerender();
    })),
  );

  const status = el('div', { class: 'art-status' });
  const genBtn = el('button', { class: 'primary', text: '🎨 Generate', style: 'margin-top:10px', onclick: () => startArt(status, genBtn) });
  const recipeBtn = a.lastGen ? el('button', { class: 'ghost', text: '↻ Recipe', style: 'margin:10px 0 0 6px',
    title: `Regenerate what produced the last image — its prompt, style and seed ${a.lastGen.seed}`
      + (a.lastGen.at ? ` (recorded ${a.lastGen.at})` : '') + '; the current model/dims/reference apply',
    onclick: () => startArt(status, recipeBtn, true) }) : null;
  const flowRunning = (state.flowJobsList || []).some(j => j.type === state.currentType && j.itemId === state.currentId);
  const flowBtn = el('button', { class: 'ghost', text: flowRunning ? '⛓ Flow (running…)' : '⛓ Flow…',
    style: 'margin:10px 0 0 6px',
    title: 'Multi-step generation: e.g. Flux 2 for prompt adherence, then Krea 2 img2img passes for '
      + 'style — sample counts fan out per step, all candidates land in a gallery to pick from',
    onclick: openFlowModal });
  if (state.isNew || !state.currentId) { genBtn.disabled = true; status.textContent = 'Save the item first (art is filed under its id).'; }
  if (state.artJob && state.artJob.itemId === state.currentId) {
    genBtn.disabled = true;
    status.textContent = `Generating… ${state.artJob.elapsed || 0}s`;
  }
  if (recipeBtn) recipeBtn.disabled = genBtn.disabled;
  flowBtn.disabled = state.isNew || !state.currentId;
  const poolBtn = el('button', { class: 'ghost', text: '🗂 Pool…', style: 'margin:10px 0 0 6px',
    title: 'Every image ever generated for this item (🎨 runs and ⛓ flow candidates) — inspect full-size and swap any of them in as the workspace art',
    onclick: openPoolModal });
  poolBtn.disabled = state.isNew || !state.currentId;

  return [
    modelRow,
    el('div', { class: 'frow' },
      el('div', { class: 'fld wide' },
        el('span', { class: 'lab' }, 'Prompt ',
          el('button', { class: 'ghost tiny', text: '↻ auto', title: 'Re-derive the template prompt from the item’s name/composition',
            onclick: () => { a.prompt = ed.promptFor(state.draft); promptArea.value = a.prompt; noChange(); } }),
          el('button', { class: 'ghost tiny', text: '✨ llm',
            title: 'Ask the local LLM (Ollama, see Settings) to write a rich prompt from the item’s full data'
              + (a.llmRefs && a.llmRefs.length ? ` and the ${a.llmRefs.length} attached reference illustration(s)` : '')
              + ' — press again to re-roll',
            onclick: async e => {
              const btn = e.target;
              btn.disabled = true; btn.textContent = '✨ thinking…';
              try {
                const out = await api('/api/art/prompt', {
                  type: state.currentType,
                  name: state.draft.display_name || state.draft.id || 'unnamed',
                  summary: ed.summarize(state.draft).filter(l => llmLineVisible(a, l)),
                  example: ed.promptFor(state.draft),
                  refArts: (a.llmRefs || []).map(r => r.art),
                  concept: a.llmConcept || '',
                  refHint: a.llmRefHint || '',
                  // composition drives the opt-in art-guide lookup server-side (cards only)
                  elements: state.draft.elements || [], pieces: state.draft.chess_pieces || [],
                  instructions: state.draft.art_instructions || '',   // per-card authored art direction
                });
                a.prompt = out.prompt; promptArea.value = out.prompt; noChange();
              } catch (err) { toast('LLM prompt failed: ' + err.message, 'err'); }
              btn.disabled = false; btn.textContent = '✨ llm';
            } }),
          state.currentType === 'card' ? el('button', { class: 'ghost tiny', text: '✨ kin',
            disabled: state.isNew || !state.currentId,
            title: 'Infer the prompt from this card\'s CANONICAL references (appointed per exact '
              + 'composition in ✨ Art guides): the anchor is the concept, the theme refs give the look; '
              + `the anchor becomes the generation reference. Adherence = the global kin default (${kinDefault()}).`,
            onclick: async e => {
              const btn = e.target;
              btn.disabled = true; btn.textContent = '✨ inferring…';
              try {
                const out = await api('/api/art/infer-recipe',
                  { type: 'card', id: state.currentId, adherence: kinDefault() });
                a.prompt = out.prompt; promptArea.value = out.prompt;
                if (out.ref) {
                  a.refSource = 'game';
                  a.refGameArt = out.ref.path;
                  a.refGameName = out.ref.name || '';
                }
                noChange();
                const src = out.inferredFrom || {};
                const st = out.stats || {};
                toast('Inferred from ' + [...(src.anchor ? ['⚓ ' + src.anchor] : []),
                  ...(src.concept || []), ...(src.theme || [])].join(', ')
                  + (st.ms ? ` (${st.mode || ''}, ${st.prompts} stored prompts, ${st.images} art images, ${Math.round(st.ms / 1000)}s)` : ''), 'ok');
                rerender();
                return;
              } catch (err) { toast('Inference failed: ' + err.message, 'err'); }
              btn.disabled = false; btn.textContent = '✨ kin';
            } }) : null,
          el('button', { class: 'ghost tiny', text: '🔎 match art',
            disabled: !(state.gameArt || state.gameHasArt),
            title: (state.gameArt || state.gameHasArt)
              ? 'Vision-analyze the item’s current art and write a prompt that recreates it — for faithful variations (the LLM guidance inputs apply here too)'
              : 'Vision-analyze the current art — no current art yet',
            onclick: async e => {
              const btn = e.target;
              btn.disabled = true; btn.textContent = '🔎 looking…';
              try {
                const out = await api('/api/art/prompt-from-art', {
                  type: state.currentType, id: state.currentId,
                  concept: a.llmConcept || '',
                  refHint: a.llmRefHint || '',
                });
                a.prompt = out.prompt; promptArea.value = out.prompt; noChange();
              } catch (err) { toast('Art analysis failed: ' + err.message, 'err'); }
              btn.disabled = false; btn.textContent = '🔎 match art';
            } })),
        llmStrip,
        promptArea),
    ),
    // the ✨ kin adherence dial: WHAT carries over from the anchor image (see server.js).
    // Bound to the GLOBAL kin default — the same value the card list's kin bar shows and
    // every ✨ action reads — so there is one source of truth, not a per-card fork.
    state.currentType === 'card'
      ? el('div', { class: 'frow' },
          fld('✨ kin — what carries over from the anchor image (global default)',
            selectInput({ get v() { return kinDefault(); }, set v(x) { setKinDefault(x); } }, 'v', KIN_MODES, () => {}),
            'anchor source = the kin bar setting (current art / canonical / custom)'))
      : null,
    // optional creative direction for the ✨ prompt writer (fullscreen view only — the
    // values still apply from the compact panel's ✨ button, they persist on the draft).
    // Both carry named-preset clusters like the shared Style fragment.
    advanced ? (() => {
      const inp = textInput(a, 'llmConcept', noChange, 'e.g. an elderly sea-witch hunched over a cauldron, more menace than majesty');
      return el('div', { class: 'frow' },
        el('div', { class: 'fld wide' },
          el('span', { class: 'lab' }, 'LLM: concept direction (optional) ',
            ...presetControls('conceptPresets', () => a.llmConcept || '',
              v => { a.llmConcept = v; inp.value = v; noChange(); })),
          inp));
    })() : null,
    advanced ? (() => {
      const inp = textInput(a, 'llmRefHint', noChange, 'e.g. copy the armor design and palette, but pose the subject in motion');
      return el('div', { class: 'frow' },
        el('div', { class: 'fld wide' },
          el('span', { class: 'lab' }, 'LLM: how to use the references (optional) ',
            ...presetControls('refHintPresets', () => a.llmRefHint || '',
              v => { a.llmRefHint = v; inp.value = v; noChange(); })),
          inp));
    })() : null,
    // per-line visibility of the item data the ✨ prompt writer receives — mechanics like
    // material costs pollute the visual concept, so any line can be hidden from the LLM.
    // Hidden lines are remembered by their text: if the line changes it reappears visible.
    advanced ? (() => {
      if (!a.llmHidden) a.llmHidden = [];
      if (!a.llmShown) a.llmShown = [];
      return el('div', { class: 'frow' },
        el('div', { class: 'fld wide' },
          el('span', { class: 'lab', text: 'Item data the LLM sees (composition & stats are always withheld — cannot be enabled)' }),
          el('div', { class: 'llm-lines' },
            ...ed.summarize(state.draft).map(line => {
              const mech = llmMechLine(line);
              return el('label', { class: 'check llm-line' + (mech ? ' locked' : '') },
                el('input', { type: 'checkbox', checked: llmLineVisible(a, line), disabled: mech,
                  title: mech ? 'Composition/stats never go to the prompt writer' : '',
                  onchange: e => {
                    a.llmHidden = a.llmHidden.filter(x => x !== line);
                    // only record deviations from the default (visible), so a re-tick resets
                    if (!e.target.checked) a.llmHidden.push(line);
                    noChange();
                  } }),
                line);
            }))));
    })() : null,
    mdl.supportsNegative ? el('div', { class: 'frow' },
      el('div', { class: 'fld wide' },
        el('span', { class: 'lab', text: 'Negative prompt (empty = the usual booru quality negatives)' }),
        el('textarea', { value: a.negative || '', rows: 2,
          placeholder: 'worst quality, low quality, watermark, …',
          oninput: e => { a.negative = e.target.value; noChange(); } })),
    ) : null,
    styleRow,
    refRow,
    refModeRow,
    el('div', { class: 'frow' },
      fld('Width', numInput(a, 'width', noChange, { min: 256, step: 64 }), null, 'narrow'),
      fld('Height', numInput(a, 'height', noChange, { min: 256, step: 64 }), null, 'narrow'),
      fld('Steps', numInput(a, 'steps', noChange, { min: 1 }), null, 'narrow'),
      fld('Guidance', numInput(a, 'guidance', noChange, { float: true, step: 0.5 }), null, 'narrow'),
      fld('Seed', numInput(a, 'seed', noChange, {}), '−1 = random', 'narrow'),
    ),
    el('div', { class: 'frow' },
      el('div', { class: 'fld' }, checkInput(a, 'rembg', noChange, 'Remove background (transparent PNG)')),
      el('div', { class: 'fld' },
        el('label', { class: 'check' },
          el('input', {
            type: 'checkbox', checked: !!a.turbo && mdl.supportsTurbo, disabled: !mdl.supportsTurbo,
            onchange: e => {
              a.turbo = e.target.checked;
              // swap the steps default along with the mode (only if the user hasn't customized)
              const turboSteps = state.settings.turboSteps || 8;
              if (a.turbo && a.steps === 20) a.steps = turboSteps;
              else if (!a.turbo && a.steps === turboSteps) a.steps = 20;
              noChange(); rerender();
            },
          }),
          mdl.supportsTurbo ? `⚡ Turbo LoRA (~${state.settings.turboSteps || 8} steps, much faster)`
            : `⚡ Turbo LoRA — Flux 2 only`)),
    ),
    el('div', { class: 'hint', text: ed.artNote }),
    el('div', {}, genBtn, recipeBtn, flowBtn, poolBtn),
    status,
    (state.artJob && state.artJob.itemId === state.currentId)
      ? el('div', { class: 'progressbar' }, el('div')) : null,
  ].filter(Boolean);
}

// The item's current imagery + actions (deploy / flip / discard), as an array of nodes.
function buildArtPreviews(rerender) {
  const t = state.types[state.currentType];
  const out = [];

  // Art the game currently shows for this item (installed art) — always presented.
  const installedArt = state.gameArt;
  if (installedArt) {
    out.push(
      el('div', { class: 'lab subtle', style: 'margin-top:10px', text: 'In-game art — ' + installedArt }),
      el('img', { class: 'art-preview', loading: 'lazy', src: '/gameart/' + installedArt + '?ts=' + Date.now() }),
    );
  }

  const hasArt = state.gameHasArt;
  if (hasArt && installedArt) {
    out.push(el('div', { class: 'lab subtle', style: 'margin-top:10px', text: 'Generated (workspace)' }));
  }
  // Flip works off whichever image is current (workspace art preferred, else in-game art)
  // and always lands in the WORKSPACE — deploying the flip stays an explicit act.
  const flipBtn = (hasArt || installedArt) ? el('button', { class: 'ghost small', text: '⇋ Flip horizontally', style: 'margin-right:6px',
    title: 'Mirror the image left-right (result goes to the workspace; press "Use in game" to deploy it)',
    onclick: () => flipArtHorizontal(hasArt ? null : installedArt) }) : null;
  if (hasArt) {
    out.push(el('img', { class: 'art-preview', src: `/art/${state.currentType}/${state.currentId}.png?ts=${Date.now()}` }));
    // Generation never touches the game's assets — this button is the explicit deploy act.
    const canDeploy = state.mode === 'game' && !state.isNew && !!t.artDir;
    if (canDeploy)
      out.push(el('div', { class: 'hint', style: 'margin-top:6px', text: 'Kept in the tool workspace until you press "Use in game" (any replaced art is backed up).' }));
    out.push(el('div', { style: 'margin-top:6px' },
      canDeploy ? el('button', { class: 'primary small', text: '⬆ Use in game', style: 'margin-right:6px', onclick: async () => {
        try {
          const out2 = await api('/api/art/deploy', { type: state.currentType, id: state.currentId });
          state.gameArt = out2.art;
          const saved = await gameSave(true);   // persist the card data too — one action, no separate Save
          if (saved) toast(`Deployed to ${out2.art} and saved (give the Godot editor focus once to import it).`, 'ok');
        } catch (e) { toast(e.message, 'err'); }
      } }) : null,
      flipBtn,
      el('button', { class: 'ghost small', text: 'Discard art', onclick: async () => {
        await api('/api/art/delete', { type: state.currentType, id: state.currentId });
        state.gameHasArt = false;
        await refreshState(true); renderSidePanels(); renderItemList();
      } })));
  } else if (installedArt) {
    out.push(el('div', { style: 'margin-top:6px' }, flipBtn));
  }
  return out;
}

// ── advanced (fullscreen) mode: same _art draft, plus the reference browser ──
function openAdvanced() {
  state.advancedOpen = true;
  state.artRefs = null;
  renderAdvanced();
  loadArtRefs();
}

function closeAdvanced() {
  state.advancedOpen = false;
  $('modal-root').replaceChildren();
  renderSidePanels();
}

async function loadArtRefs() {
  const d = state.draft || {};
  try {
    const out = await api('/api/art/references', {
      elements: d.elements || [], chess_pieces: d.chess_pieces || [], excludeId: state.currentId });
    state.artRefs = out.refs;
  } catch (e) {
    state.artRefs = [];
    toast('Loading references failed: ' + e.message, 'err');
  }
  if (state.advancedOpen) renderAdvanced();
}

function renderAdvanced() {
  const a = artDraft();
  const mdl = state.artModels[a.model];
  const noChange = () => { a.touched = true; state.dirty = true; $('dirty-flag').hidden = false; };
  // a full re-render replaces the DOM — carry the reference column's scroll across so
  // attaching a ref deep in the list doesn't bounce the user back to the top
  const prevRefsCol = document.querySelector('.modal.advanced .advanced-col.refs');
  const keepScroll = prevRefsCol ? prevRefsCol.scrollTop : 0;

  const refRow = r => {
    const isImg = a.refSource === 'game' && a.refGameArt === r.art;
    const isLlm = (a.llmRefs || []).some(x => x.art === r.art);
    const comp = [...(r.elements || []), ...(r.chess_pieces || [])].join(' · ');
    return el('div', { class: 'ref-row' + (isImg ? ' attached-img' : '') + (isLlm ? ' attached-llm' : '') },
      el('img', { class: 'thumb', loading: 'lazy', src: '/gameart/' + r.art }),
      el('span', { class: 'ref-name' }, r.name,
        el('span', { class: 'ref-comp', text: (comp || '—') + (r.enemy ? ' · enemy' : '') })),
      el('button', {
        class: 'ghost tiny', text: isImg ? '✕ img' : '→ img', disabled: !mdl.supportsRef,
        title: mdl.supportsRef ? 'Use as the image-model reference (img2img / reference latent)'
          : `${mdl.label} has no reference path`,
        onclick: () => {
          if (isImg) { a.refSource = 'none'; a.refGameArt = null; a.refGameName = null; }
          else { a.refSource = 'game'; a.refGameArt = r.art; a.refGameName = r.name; }
          noChange(); renderAdvanced();
        } }),
      el('button', {
        class: 'ghost tiny', text: isLlm ? '− llm' : '+ llm',
        title: 'Show this illustration to the LLM prompt writer (style reference, up to 4)',
        onclick: () => {
          if (!a.llmRefs) a.llmRefs = [];
          if (isLlm) a.llmRefs = a.llmRefs.filter(x => x.art !== r.art);
          else if (a.llmRefs.length >= 4) { toast('At most 4 LLM references.', 'err'); return; }
          else a.llmRefs.push({ id: r.id, name: r.name, art: r.art });
          noChange(); renderAdvanced();
        } }),
    );
  };

  // the list rebuilds IN PLACE on filter changes — typing never re-renders the modal,
  // so the filter input keeps focus and the column keeps its scroll position
  const listEl = el('div', { class: 'adv-ref-list' });
  const rebuildList = () => {
    const f = (state.refFilter || '').toLowerCase();
    const ef = state.refEnemyFilter || 'all';
    const rows = (state.artRefs || [])
      .filter(r => ef === 'all' || (ef === 'enemy') === !!r.enemy)
      .filter(r => !f || `${r.name} ${r.id} ${[...(r.elements || []), ...(r.chess_pieces || [])].join(' ')}`.toLowerCase().includes(f))
      .map(refRow);
    listEl.replaceChildren(...(rows.length ? rows
      : [el('div', { class: 'hint', text: state.artRefs === null ? 'Loading…'
          : state.artRefs.length ? 'No references match the filter.' : 'No other card art in the game yet.' })]));
  };
  rebuildList();

  const filterRow = el('div', { class: 'frow ref-filter' },
    el('input', {
      type: 'text', value: state.refFilter || '', placeholder: 'filter by name / composition…',
      oninput: e => { state.refFilter = e.target.value; rebuildList(); },
    }),
    selectInput(state, 'refEnemyFilter', [
      { value: 'all', label: 'All cards' },
      { value: 'player', label: 'Player cards' },
      { value: 'enemy', label: 'Enemy cards' },
    ], rebuildList));

  const modal = el('div', { class: 'modal advanced' },
    el('div', { class: 'advanced-head' },
      el('h2', { text: `Advanced art — ${state.draft.display_name || state.currentId || 'new item'}` }),
      el('button', { class: 'ghost', text: '⇱ Collapse', title: 'Back to the compact art panel (nothing is lost)', onclick: closeAdvanced })),
    el('div', { class: 'advanced-cols' },
      el('div', { class: 'advanced-col refs' },
        el('h3', { text: 'References (ranked by composition)' }),
        el('div', { class: 'hint', text: 'The bare piece version of this card ranks first, then the closest compositions. → img feeds the image model; + llm shows it to the prompt writer.' }),
        filterRow,
        listEl),
      el('div', { class: 'advanced-col' },
        el('h3', { text: 'Generation' }),
        ...buildArtControls(renderAdvanced, true)),
      el('div', { class: 'advanced-col previews' },
        el('h3', { text: 'Current imagery' }),
        ...buildArtPreviews(renderAdvanced))));
  $('modal-root').replaceChildren(modal);
  modal.querySelector('.advanced-col.refs').scrollTop = keepScroll;
}

// Mirror the item's art left-right on a canvas and store the result as WORKSPACE art
// (the server stays image-library-free). fromGameArt = flip the installed art instead
// of workspace art — the flipped copy still only reaches the game via "Use in game".
async function flipArtHorizontal(fromGameArt) {
  const src = fromGameArt
    ? '/gameart/' + fromGameArt + '?ts=' + Date.now()
    : `/art/${state.currentType}/${state.currentId}.png?ts=${Date.now()}`;
  try {
    const img = new Image();
    img.src = src;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = img.naturalWidth; c.height = img.naturalHeight;
    const ctx = c.getContext('2d');
    ctx.translate(c.width, 0); ctx.scale(-1, 1);
    ctx.drawImage(img, 0, 0);
    await api('/api/art/put', { type: state.currentType, id: state.currentId,
      dataBase64: c.toDataURL('image/png').split(',')[1] });
    state.gameHasArt = true;
    renderSidePanels();
  } catch (e) { toast('Flip failed: ' + (e.message || e), 'err'); }
}

// A named-preset cluster (＋ save / − delete / select) for one text value. Presets live
// globally in settings[key] as {name: text}; getValue/setValue bridge to wherever the
// live text is (the shared style fragment, or a per-item _art draft field).
function presetControls(key, getValue, setValue) {
  if (!state.settings[key]) state.settings[key] = {};
  const sel = el('select', {
    onchange: e => { if (e.target.value) setValue(state.settings[key][e.target.value] || ''); },
  });
  const rebuild = () => {
    sel.replaceChildren(el('option', { value: '', text: 'presets…' }));
    for (const name of Object.keys(state.settings[key]).sort())
      sel.append(el('option', { value: name, text: name }));
  };
  rebuild();
  const persist = async () => {
    try { await api('/api/settings', { [key]: state.settings[key] }); }
    catch (e) { toast('Saving presets failed: ' + e.message, 'err'); }
  };
  return [
    el('button', { class: 'ghost tiny', text: '＋ save preset', title: 'Save the current text as a named preset',
      onclick: async () => {
        const name = (window.prompt('Preset name:', '') || '').trim();
        if (!name) return;
        state.settings[key][name] = getValue();
        rebuild(); sel.value = name;
        await persist();
        toast(`Preset "${name}" saved.`, 'ok');
      } }),
    el('button', { class: 'ghost tiny', text: '− delete', title: 'Delete the selected preset',
      onclick: async () => {
        if (!sel.value) return;
        delete state.settings[key][sel.value];
        rebuild();
        await persist();
      } }),
    sel,
  ];
}

// The style fragment is global — persist it (debounced while typing).
let _styleTimer = null;
function saveStyleSoon() {
  clearTimeout(_styleTimer);
  _styleTimer = setTimeout(saveStyleNow, 800);
}
async function saveStyleNow() {
  clearTimeout(_styleTimer);
  try {
    await api('/api/settings', { artStyle: state.settings.artStyle || '', stylePresets: state.settings.stylePresets || {} });
  } catch (e) { toast('Saving style failed: ' + e.message, 'err'); }
}

// `recipe` = the ↻ Recipe button: reproduce the LAST generation exactly — its
// recorded prompt, style fragment and seed (the current model/dims/reference
// still apply; edit one field first for a controlled variation).
async function startArt(statusEl, btn, recipe) {
  const a = state.draft._art;
  btn.disabled = true;
  statusEl.className = 'art-status';
  statusEl.textContent = 'Queueing…';
  await saveStyleNow();
  const last = recipe && a.lastGen ? a.lastGen : null;
  const base = last ? last.prompt : (a.prompt || EDITORS[state.currentType].promptFor(state.draft));
  // An enemy unit's TRIBE contributes its canonical style fragment ahead of the shared style
  // (fresh generations only — a recipe re-run reproduces exactly the style it recorded).
  const tribeStyle = (!last && state.currentType === 'card' && state.draft.enemy_only && state.draft.tribe)
    ? (((state.game.tribe || []).find(t => t.id === state.draft.tribe) || {}).style || '') : '';
  const style = last ? (last.style || '')
    : [tribeStyle, (state.settings.artStyle || '').trim()].filter(Boolean).join(', ');
  // a random seed resolves HERE, not server-side, so the recipe records what actually ran
  const seed = last ? last.seed
    : (a.seed != null && a.seed >= 0 ? a.seed : Math.floor(Math.random() * 2 ** 32));
  try {
    const { jobId } = await api('/api/art/generate', {
      type: state.currentType, id: state.currentId,
      prompt: style ? base + ', ' + style : base,
      negative: a.negative || '',
      width: a.width, height: a.height,
      steps: a.steps, guidance: a.guidance, seed, rembg: a.rembg,
      useRef: !!a.refSource && a.refSource !== 'none',
      refUpload: a.refSource === 'upload' ? a.refUpload : undefined,
      refGameArt: a.refSource === 'game' ? a.refGameArt : undefined,
      refMode: a.refMode, denoise: a.denoise,
      turbo: !!a.turbo && !!(state.artModels[a.model || 'flux2'] || {}).supportsTurbo,
      model: a.model || 'flux2',
    });
    state.artJob = { jobId, itemId: state.currentId, type: state.currentType, elapsed: 0,
      // stamped into the entry's recipe (tool.art.last) when the job completes
      stamp: { seed, prompt: base, style, at: new Date().toISOString().slice(0, 10) } };
    renderArtPanel();
    pollArt();
    kickQueue();
  } catch (e) {
    btn.disabled = false;
    statusEl.className = 'art-status err';
    statusEl.textContent = e.message;
  }
}

async function pollArt() {
  if (!state.artJob) return;
  try {
    const j = await api('/api/art/job?id=' + state.artJob.jobId);
    state.artJob.elapsed = j.elapsed;
    if (j.status === 'running' || j.status === 'queued') {
      if (state.currentId === state.artJob.itemId) {
        // both views (compact panel and the advanced modal) show a live status line
        const txt = j.status === 'queued' ? 'Queued…' : `Generating… ${j.elapsed}s`;
        for (const s of document.querySelectorAll('.art-status')) s.textContent = txt;
      }
      setTimeout(pollArt, 2000);
      return;
    }
    const finished = state.artJob;
    state.artJob = null;
    if (j.status === 'done') {
      const hasSlot = !!(state.types[finished.type] && state.types[finished.type].artDir);
      toast(`Art ready for ${finished.itemId}.` + (hasSlot
        ? ' It stays in the workspace — press "⬆ Use in game" when you want it deployed.'
        : ' (Reference only — the game has no art slot for this type.)'), 'ok');
      // record what produced this image on the entry's recipe (only stamped on
      // SUCCESS — a failed job leaves the previous image and its recipe intact)
      if (state.currentId === finished.itemId && state.currentType === finished.type
          && state.draft && state.draft._art && finished.stamp) {
        state.draft._art.lastGen = finished.stamp;
        state.draft._art.touched = true;
        state.dirty = true;
        $('dirty-flag').hidden = false;
      }
      if (state.currentId === finished.itemId) state.gameHasArt = true;
      await refreshState(true);
      renderItemList();
      if (state.currentId === finished.itemId) renderSidePanels();
    } else {
      toast('Art generation failed: ' + (j.error || 'unknown'), 'err');
      if (state.currentId === finished.itemId) renderSidePanels();
    }
  } catch (e) {
    setTimeout(pollArt, 4000);
  }
}

// ── set generator: a composition family as INDIVIDUAL card items ─────────────
// Not a content type — a batch-create. Each generated entry is a real card you can open,
// differentiate and edit like any other; stats stay derived (the game computes them).
const SET_PIECES = ['pawn', 'knight', 'bishop', 'rook', 'queen'];

function generateSetCards(cfg) {
  const els = [cfg.a, cfg.b].filter(Boolean).sort();
  if (!els.length) return [];
  const combos = [];
  if (cfg.spell) combos.push([]);
  if (cfg.singles) for (const p of SET_PIECES) combos.push([p]);
  if (cfg.pairs)
    for (let i = 0; i < SET_PIECES.length; i++)
      for (let j = i; j < SET_PIECES.length; j++) combos.push([SET_PIECES[i], SET_PIECES[j]]);
  return combos.map(chess => {
    const sorted = [...chess].sort();
    const card = { id: [...els, ...sorted].join('_'), _derive_stats: true, elements: els.slice() };
    // named from birth — ✨ recipe inference leans on the name for the concept
    card.display_name = defaultSetCardName(els, sorted);
    if (sorted.length) card.chess_pieces = sorted;
    if (cfg.description) card.description = cfg.description;
    if (cfg.effects.length) card.effects = cfg.effects.map(cleanEffectForDeploy);
    return card;
  });
}

// Composition identity — elements and pieces each sorted. Matches the game's
// CardData.composition_key semantics, so the set generator can spot an existing
// card that OWNS a slot's composition even under a custom id (e.g. frost_adept).
function setCompKey(d) {
  return [...(d.elements || [])].sort().join('_') + '|' + [...(d.chess_pieces || [])].sort().join('_');
}

// Plans a set generation against the live game data: which slots are genuinely new,
// which compositions already exist ELSEWHERE (their definitions get PULLED — moved
// verbatim into the family file), which are already in place, and which ids are
// taken by an unrelated composition (hands off).
function planSetCards(cfg) {
  const cards = generateSetCards(cfg);
  const setFile = [cfg.a, cfg.b].filter(Boolean).sort().join('_') + '_units.json';
  const byComp = new Map();
  for (const g of state.game.card || []) {
    if (!(g.elements || []).length && !(g.chess_pieces || []).length) continue;
    const k = setCompKey(g);
    if (!byComp.has(k)) byComp.set(k, g);
  }
  const ids = new Set([...state.vocab.cards.map(c => c.id), ...(state.items.card || []).map(i => i.id)]);
  const plan = { fresh: [], moves: [], inPlace: [], taken: [], setFile };
  for (const c of cards) {
    const owner = byComp.get(setCompKey(c));
    if (owner) {
      if (owner.file === setFile) plan.inPlace.push(owner.id);
      else plan.moves.push(owner);
    } else if (ids.has(c.id)) plan.taken.push(c.id);
    else plan.fresh.push(c);
  }
  return plan;
}

// The display name of the base card owning EXACTLY this composition (the naming
// vocabulary lives on the base combo cards: fire_water = "Steam", bishop_pawn =
// "Paladin"). Entries whose name is just their id don't count as named.
function comboName(els, pieces) {
  const key = setCompKey({ elements: els, chess_pieces: pieces });
  const hit = (state.game.card || []).find(g =>
    setCompKey(g) === key && g.name && g.name !== g.id);
  return hit ? hit.name : null;
}

// Default set-card name: <element combo name> <piece combo name> —
// fire_water_pawn_bishop → "Steam Paladin". Falls back to capitalized ids when a
// base combo card is missing or unnamed ("Air Earth Pawn").
function defaultSetCardName(els, pieces) {
  const cap = s => s.charAt(0).toUpperCase() + s.slice(1);
  const elName = els.length ? (comboName(els, []) || els.map(cap).join(' ')) : '';
  const pieceName = pieces.length ? (comboName([], pieces) || pieces.map(cap).join(' ')) : '';
  return [elName, pieceName].filter(Boolean).join(' ');
}

// ≡ Bulk edit — act on the whole currently-filtered card set at once. Four actions: set a
// stat to a constant, pump a stat by ±delta (relative, so uneven values stay relative),
// grant an ability id, grant authored effect(s). Each posts to /api/game/bulk, which writes
// every entry through the normal per-card save (backups + Revert + validation intact).
function openBulkEditor() {
  const ids = (state.bulkIds || []).slice();
  const n = ids.length;
  if (!n) { toast('No cards match the current filter.', 'err'); return; }
  const STATS = [
    { value: 'cost', label: 'Mana cost' }, { value: 'attack', label: 'Attack' },
    { value: 'health', label: 'Health' }, { value: 'speed', label: 'Speed' },
    { value: 'shield', label: 'Shield' },
  ];
  const close = () => $('modal-root').replaceChildren();
  async function run(ops, verb) {
    let out;
    try { out = await api('/api/game/bulk', { type: 'card', ids, ops }); }
    catch (e) { toast('Bulk edit failed: ' + e.message, 'err'); return; }
    const bits = [`${verb}: ${out.updated} updated`];
    if (out.skipped) bits.push(`${out.skipped} unchanged`);
    if (out.errors && out.errors.length) { bits.push(`${out.errors.length} failed`); console.warn('bulk errors', out.errors); }
    toast(bits.join(' · '), out.errors && out.errors.length ? 'err' : 'ok');
    state.gameEdited = true;
    await refreshState(true);
    close();
  }

  const setCfg = { attr: 'cost', value: 0 };
  const setBox = groupBox('Set a stat',
    el('div', { class: 'frow' },
      fld('Attribute', selectInput(setCfg, 'attr', STATS, () => {}), null, 'narrow'),
      fld('Value', numInput(setCfg, 'value', () => {}), null, 'narrow'),
      el('button', { class: 'primary', text: 'Set on all', onclick: () =>
        run([{ kind: 'set', attr: setCfg.attr, value: setCfg.value }], `Set ${setCfg.attr}=${setCfg.value}`) })),
    el('div', { class: 'hint', text: 'Writes the same value to every matched card (added if missing). Clamped to the stat’s floor.' }));

  const pumpCfg = { attr: 'cost', delta: -1 };
  const pump = d => run([{ kind: 'pump', attr: pumpCfg.attr, delta: d }], `${pumpCfg.attr} ${d >= 0 ? '+' : ''}${d}`);
  const pumpBox = groupBox('Pump a stat (±, relative)',
    el('div', { class: 'frow' },
      fld('Attribute', selectInput(pumpCfg, 'attr', STATS, () => {}), null, 'narrow'),
      el('button', { class: 'ghost', text: '−1', onclick: () => pump(-1) }),
      el('button', { class: 'ghost', text: '+1', onclick: () => pump(1) }),
      fld('Custom delta', numInput(pumpCfg, 'delta', () => {}), null, 'narrow'),
      el('button', { class: 'primary', text: 'Apply delta', onclick: () => pump(pumpCfg.delta) })),
    el('div', { class: 'hint', text: 'Adds the delta to each card’s current value — uneven starting values stay relative. Cards that derive their stats (no explicit value) are skipped. Clamped to the stat’s floor.' }));

  const abils = abilityIds(editorCtx());
  const abCfg = { ability: abils[0] || '' };
  const abBox = groupBox('Grant an ability',
    abils.length
      ? el('div', { class: 'frow' },
          fld('Ability', selectInput(abCfg, 'ability', abils, () => {})),
          el('button', { class: 'primary', text: 'Grant to all', onclick: () => {
            if (abCfg.ability) run([{ kind: 'grant_ability', ability: abCfg.ability }], `Grant ${abCfg.ability}`); } }))
      : el('div', { class: 'hint', text: 'No abilities defined yet — create some in the Abilities tab first.' }),
    el('div', { class: 'hint', text: 'Adds the ability id to every matched card that doesn’t already have it.' }));

  const fxScratch = { effects: [] };
  const fxWrap = el('div');
  renderEffectList(fxWrap, fxScratch.effects, fxCtx(editorCtx(), 'each matched card'), () => {});
  const fxBox = groupBox('Grant an effect',
    fxWrap,
    el('div', { class: 'frow', style: 'margin-top:8px' },
      el('button', { class: 'primary', text: 'Grant to all', onclick: () => {
        const eff = fxScratch.effects.map(cleanEffectForDeploy);
        if (!eff.length) { toast('Author at least one effect first.', 'err'); return; }
        run(eff.map(e => ({ kind: 'grant_effect', effect: e })), `Grant ${eff.length} effect(s)`); } })),
    el('div', { class: 'hint', text: 'Appends the authored effect(s) to every matched card’s effect list.' }));

  const modal = el('div', { class: 'modal', style: 'width:680px; max-height:88vh; overflow:auto' },
    el('h2', { text: `Bulk edit — ${n} card${n === 1 ? '' : 's'} match the filter` }),
    el('div', { class: 'hint', text: `Every action applies to ALL ${n} filtered cards at once. Each writes through the normal per-card save, so Revert still works per card.` }),
    setBox, pumpBox, abBox, fxBox,
    el('div', { class: 'modal-actions' }, el('button', { class: 'ghost', text: 'Close', onclick: close })));
  $('modal-root').replaceChildren(modal);
}

function openSetGenerator() {
  const cfg = { a: 'water', b: '', singles: true, pairs: true, spell: false,
    description: '', effects: [], install: true };
  const preview = el('div', { class: 'subtle mono', style: 'margin-top:8px; line-height:1.6' });
  const refresh = () => {
    const plan = planSetCards(cfg);
    if (!plan.fresh.length && !plan.moves.length && !plan.inPlace.length && !plan.taken.length) {
      preview.textContent = 'pick at least one element';
      return;
    }
    preview.textContent = `${plan.fresh.length} new cards`
      + (plan.moves.length ? ` · ${plan.moves.length} pulled in from other files (${plan.moves.map(m => `${m.id} — ${m.file}`).join(', ')})` : '')
      + (plan.inPlace.length ? ` · ${plan.inPlace.length} already in place` : '')
      + (plan.taken.length ? ` · ${plan.taken.length} skipped (id taken by a different composition: ${plan.taken.join(', ')})` : '')
      + (plan.fresh.length ? ': ' + plan.fresh.map(c => c.id).join(', ') : '');
  };
  const fxWrap = el('div');
  renderEffectList(fxWrap, cfg.effects, fxCtx(editorCtx(), 'each generated card'), refresh);
  const modal = el('div', { class: 'modal', style: 'width:640px' },
    el('h2', { text: 'Generate a composition set' }),
    el('div', { class: 'frow' },
      fld('Element A', selectInput(cfg, 'a', state.vocab.elements.map(e => ({ value: e, label: labelOf('element', e) })), refresh)),
      fld('Element B', selectInput(cfg, 'b', state.vocab.elements.map(e => ({ value: e, label: labelOf('element', e) })), refresh,
        { optional: true, emptyLabel: '(none — single element)' }), 'same element twice is valid'),
    ),
    el('div', { class: 'frow' },
      el('div', { class: 'fld' }, checkInput(cfg, 'singles', refresh, 'Single-piece units (5)')),
      el('div', { class: 'fld' }, checkInput(cfg, 'pairs', refresh, 'Two-piece units (15)')),
      el('div', { class: 'fld' }, checkInput(cfg, 'spell', refresh, 'Pure-element spell entry')),
    ),
    el('div', { class: 'frow' },
      el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Description (stamped on each card — edit per card afterwards)' }),
        el('textarea', { value: '', oninput: e => { cfg.description = e.target.value; } })),
    ),
    el('span', { class: 'lab subtle', text: 'Starting effects (stamped on each card — edit per card afterwards):' }),
    fxWrap,
    preview,
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Cancel', onclick: () => $('modal-root').replaceChildren() }),
      el('button', { class: 'primary', text: 'Generate cards', onclick: async () => {
        const plan = planSetCards(cfg);
        if (!plan.fresh.length && !plan.moves.length) { toast('Nothing to do — every composition already lives in ' + plan.setFile + '.', 'err'); return; }
        // existing compositions are PULLED in first — their definitions move verbatim
        // into the family file (Revert on such an entry puts it back where it came from)
        let moved = 0, made = 0;
        for (const m of plan.moves) {
          try {
            await api('/api/game/move-entry', { type: 'card', id: m.id, file: plan.setFile });
            moved++;
          } catch (e) { toast(`${m.id}: ${e.message}`, 'err'); }
        }
        // the whole family lives in ONE normally-named game file, each entry an ordinary card
        for (const card of plan.fresh) {
          try {
            await api('/api/game/save', { type: 'card', file: plan.setFile, data: card });
            made++;
          } catch (e) { toast(`${card.id}: ${e.message}`, 'err'); }
        }
        $('modal-root').replaceChildren();
        toast(`${made} cards saved` + (moved ? `, ${moved} existing pulled in,` : '')
          + ` into data/cards/${plan.setFile} — in the game (restart it to see them).`, 'ok');
        await refreshState();
      } }),
    ));
  $('modal-root').replaceChildren(modal);
  refresh();
}

// ── full-size inspection overlay ─────────────────────────────────────────────
// Flow galleries and the generation pool both use it — thumbnails alone were too
// small to judge candidates by (user feedback).
function openLightbox(src, caption, onUse) {
  const overlay = el('div', { style: 'position:fixed; inset:0; background:rgba(10,10,14,.85); '
      + 'z-index:2000; display:flex; flex-direction:column; align-items:center; justify-content:center; gap:10px' },
    el('img', { src, style: 'max-width:92vw; max-height:78vh; border-radius:8px' }),
    caption ? el('div', { style: 'color:#eee; font-size:13px', text: caption }) : null,
    el('div', {},
      onUse ? el('button', { class: 'primary', text: '✔ Use as workspace art', onclick: async () => {
        try { await onUse(); } catch (e) { toast(e.message, 'err'); }
        overlay.remove();
      } }) : null,
      el('button', { class: 'ghost', text: 'Close', style: 'margin-left:8px', onclick: () => overlay.remove() })));
  overlay.onclick = e => { if (e.target === overlay) overlay.remove(); };
  document.body.append(overlay);
}

// ── 🗂 the generation pool: every image ever generated for this item ──────────
async function openPoolModal() {
  const type = state.currentType, id = state.currentId;
  if (!id || state.isNew) return;
  let pool = [];
  try { pool = (await api(`/api/art/pool?type=${type}&id=${id}`)).pool || []; }
  catch (e) { toast(e.message, 'err'); return; }
  const grid = el('div', { style: 'display:flex; flex-wrap:wrap; gap:10px; margin-top:8px' });
  const title = el('span', { class: 'subtle' });
  const render = () => {
    title.textContent = `${id} (${pool.length})`;
    grid.replaceChildren();
    if (!pool.length) {
      grid.append(el('div', { class: 'subtle', text: 'Nothing pooled yet — every 🎨 and ⛓ generation lands here automatically.' }));
      return;
    }
    for (const entry of [...pool].reverse()) {   // newest first
      const meta = `${entry.source}${entry.step ? ' s' + entry.step : ''} · ${entry.model} · seed ${entry.seed} · ${String(entry.at || '').slice(0, 10)}`;
      const src = `/poolart/${type}/${id}/${entry.file}`;
      const use = async () => {
        const out = await api('/api/art/pool-use', { type, id, file: entry.file });
        state.gameHasArt = true;
        toast(`Pool #${entry.n} is now the workspace art`
          + (out.entry.needsRembg && state.types[type].rembg ? ' (background removed)' : '') + '.', 'ok');
        renderSidePanels();
      };
      // set it as the art, deploy it, AND save the card data — one step, no separate Save
      const useAndDeploy = async () => {
        const out = await api('/api/art/pool-use', { type, id, file: entry.file });
        state.gameHasArt = true;
        const out2 = await api('/api/art/deploy', { type, id });
        state.gameArt = out2.art;
        const saved = await gameSave(true);
        if (saved) toast(`Pool #${entry.n} is now the card art, deployed and saved to the game`
          + (out.entry.needsRembg && state.types[type].rembg ? ' (background removed)' : '') + '.', 'ok');
      };
      grid.append(el('div', { style: 'width:224px' },
        el('img', { src, loading: 'lazy', style: 'width:224px; height:auto; border-radius:6px; cursor:zoom-in',
          onclick: () => openLightbox(src, `#${entry.n} · ${meta}`, use) }),
        el('div', { class: 'subtle', style: 'font-size:11px; margin-top:2px', text: meta }),
        el('div', {},
          el('button', { class: 'ghost tiny', text: '✔ use', title: 'Set as the workspace art (deploying stays a separate step)', onclick: async e => {
            e.target.disabled = true;
            try { await use(); } catch (err) { toast(err.message, 'err'); }
            e.target.disabled = false;
          } }),
          el('button', { class: 'ghost tiny', text: '⬆ to game', title: 'Set as the card art AND deploy it into the game assets in one step', onclick: async e => {
            e.target.disabled = true;
            try { await useAndDeploy(); } catch (err) { toast(err.message, 'err'); }
            e.target.disabled = false;
          } }),
          el('button', { class: 'ghost tiny', text: '✕', title: 'Permanently delete this image from disk', onclick: async () => {
            try {
              await api('/api/art/pool-delete', { type, id, file: entry.file });
              pool = pool.filter(x => x.file !== entry.file);
              render();
            } catch (err) { toast(err.message, 'err'); }
          } }))));
    }
  };
  render();
  $('modal-root').replaceChildren(el('div', { class: 'modal', style: 'width:900px; max-height:86vh; overflow-y:auto' },
    el('h2', {}, '🗂 Generation pool — ', title),
    el('div', { class: 'hint', text: 'Every image generated for this item (🎨 runs and ⛓ flow candidates), newest first. '
      + 'Click to inspect full-size; ✔ use swaps it in as the workspace art; ⬆ to game does that AND deploys it into the game '
      + 'in one step; ✕ permanently deletes the image from disk.' }),
    grid,
    el('div', { class: 'modal-actions' },
      el('button', { class: 'danger', text: '🗑 Delete all from disk',
        title: 'Permanently delete every pooled image AND the last flow\'s candidates for this item. '
          + 'The current workspace art and deployed game art are untouched.',
        onclick: async e => {
          if (!pool.length) { toast('The pool is already empty.', 'ok'); return; }
          if (!confirm(`Permanently delete all ${pool.length} pooled images AND the last flow's candidate images for "${id}" from disk?\n\nThe card's current art and deployed game art are NOT touched.`)) return;
          e.target.disabled = true;
          try {
            await api('/api/art/pool-clear', { type, id });
            pool = [];
            render();
            toast('All generation intermediates for this item deleted from disk.', 'ok');
          } catch (err) { toast(err.message, 'err'); }
          e.target.disabled = false;
        } }),
      el('button', { class: 'ghost', text: 'Close', onclick: () => $('modal-root').replaceChildren() }))));
}

// ── ⛓ multi-step generation flows ───────────────────────────────────────────
// The best-results process automated: e.g. Flux 2 first (prompt adherence), then a
// Krea 2 img2img pass at ~half denoise (style). Sample counts multiply through the
// steps; every output lands in a candidate gallery and the pick becomes the item's
// workspace art (rembg applied there, for types that want it).
function flowStepsTotal(steps) {
  let branch = 1, total = 0;
  for (const st of steps) { branch *= (parseInt(st.samples, 10) || 1); total += branch; }
  return total;
}

function openFlowModal() {
  const type = state.currentType, id = state.currentId;
  if (!id || state.isNew) return;
  if (!state.flowSteps) state.flowSteps = [
    { model: 'flux2', samples: 1, turbo: true },
    { model: 'krea2', samples: 3, denoise: 0.55 },
  ];
  const cfg = state.flowSteps;
  const a0 = artDraft();
  // step-1 ANCHOR: the concept image the whole tree grows from. Choices: current art,
  // the composition's CANONICAL concept ref (appointed in ✨ Art guides — mandatory,
  // refuses when unappointed), the recipe's own reference, an upload — defaulting to
  // the recipe's pick when there is one, "none" otherwise.
  const anchorCfg = { source: (a0.refSource && a0.refSource !== 'none') ? a0.refSource : 'none' };
  const buildAnchorOpts = () => [
    { value: 'none', label: 'None — from scratch' },
    (state.gameArt || state.gameHasArt) ? { value: 'current', label: 'Current art' } : null,
    (type === 'card' && (state.draft && (state.draft.chess_pieces || []).length))
      ? { value: 'canonical', label: 'Canonical concept (appointed in ✨ Art guides)' } : null,
    a0.refGameArt ? { value: 'game', label: `Custom reference: ${a0.refGameName || a0.refGameArt}` } : null,
    a0.refUpload ? { value: 'upload', label: `Uploaded: ${a0.refUploadLabel || a0.refUpload}` } : null,
  ].filter(Boolean);
  let anchorOpts = buildAnchorOpts();
  if (!anchorOpts.some(o => o.value === anchorCfg.source)) anchorCfg.source = 'none';
  const anchorSelWrap = el('span');
  const rebuildAnchorSel = () => {
    anchorOpts = buildAnchorOpts();
    // deferred: renderSteps is declared below (this select is built before it exists)
    anchorSelWrap.replaceChildren(selectInput(anchorCfg, 'source', anchorOpts, () => renderSteps()));
  };
  rebuildAnchorSel();
  const stepsWrap = el('div');
  const totalLine = el('div', { class: 'hint', style: 'margin:6px 0' });
  const gallery = el('div');
  const status = el('div', { class: 'art-status' });
  let currentPrompt = '';

  const renderSteps = () => {
    stepsWrap.replaceChildren();
    const anchored = anchorCfg.source !== 'none';
    cfg.forEach((st, i) => {
      const takesInput = i > 0 || anchored;
      if (takesInput && st.model === 'krea2' && !st.denoise) st.denoise = 0.55;
      if (st.model === 'flux2' && st.turbo == null) st.turbo = true;   // turbo on by default
      const modelOpts = Object.entries(state.artModels)
        .filter(entry => !takesInput || entry[1].supportsRef)   // input-fed steps must accept an image
        .map(entry => ({ value: entry[0], label: entry[1].label }));
      if (takesInput && !modelOpts.some(o => o.value === st.model)) st.model = 'krea2';
      stepsWrap.append(el('div', { class: 'frow' },
        el('span', { class: 'lab', style: 'align-self:center; min-width:48px', text: 'Step ' + (i + 1) }),
        fld('Model', selectInput(st, 'model', modelOpts, renderSteps)),
        fld('Samples', numInput(st, 'samples', renderSteps, { min: 1, max: 8 }), takesInput ? 'per input image' : null, 'narrow'),
        (takesInput && st.model === 'krea2')
          ? fld('Denoise', numInput(st, 'denoise', renderSteps, { float: true, step: 0.05, min: 0.05, max: 1 }),
              i === 0 ? 'adherence to the anchor — lower = closer' : 'lower = closer to the input', 'narrow')
          : null,
        fld('Steps', numInput(st, 'steps', renderSteps, { min: 1, optional: true, placeholder: 'default' }), null, 'narrow'),
        fld('Guidance', numInput(st, 'guidance', renderSteps, { float: true, step: 0.5, optional: true, placeholder: 'default' }), null, 'narrow'),
        st.model === 'flux2' ? el('div', { class: 'fld' }, checkInput(st, 'turbo', renderSteps, '⚡ Turbo')) : null,
        cfg.length > 1 ? el('button', { class: 'ghost tiny', text: '✕', style: 'align-self:center',
          onclick: () => { cfg.splice(i, 1); renderSteps(); } }) : null,
      ));
    });
    const total = flowStepsTotal(cfg);
    totalLine.textContent = `${total} image${total === 1 ? '' : 's'} will be generated`
      + (total > 24 ? ' — OVER the cap of 24, trim the sample counts' : '');
  };
  renderSteps();

  const renderGallery = nodes => {
    gallery.replaceChildren();
    if (!nodes || !nodes.length) return;
    const bySteps = new Map();
    for (const nd of nodes) {
      if (!bySteps.has(nd.step)) bySteps.set(nd.step, []);
      bySteps.get(nd.step).push(nd);
    }
    for (const stepN of [...bySteps.keys()].sort((a, b) => a - b)) {
      const list = bySteps.get(stepN);
      const mdl = state.artModels[list[0].model];
      gallery.append(el('div', { class: 'lab subtle', style: 'margin-top:10px',
        text: `Step ${stepN} — ${mdl ? mdl.label : list[0].model} (click a candidate to use it)` }));
      const rowEl = el('div', { style: 'display:flex; flex-wrap:wrap; gap:10px; margin-top:4px' });
      for (const nd of list) {
        // ?v=seed cache-busts: flow filenames (1_01.png…) repeat every run, and the browser
        // serves the stale cached image for a repeated URL even under Cache-Control: no-store.
        const src = `/flowart/${type}/${id}/${nd.file}?v=${nd.seed}`;
        const caption = `#${nd.n} · seed ${nd.seed}` + (nd.parent ? ` · from #${nd.parent}` : '');
        const pick = async (deploy) => {
          const out = await api('/api/art/flow-pick', { type, id, file: nd.file });
          state.gameHasArt = true;
          // stamp the pick into the entry's recipe, like a normal generation would
          if (state.draft && state.currentId === id) {
            const a = artDraft();
            a.lastGen = { seed: (out.node || nd).seed, prompt: currentPrompt || (a.prompt || ''),
              style: '', at: new Date().toISOString().slice(0, 10) };
            a.touched = true;
            state.dirty = true;
            $('dirty-flag').hidden = false;
          }
          let msg = `Candidate #${nd.n} is now this item's workspace art`
            + (state.types[type].rembg ? ' (background removed)' : '');
          if (deploy) {   // …deploy it into the game AND save the card data — one step
            const out2 = await api('/api/art/deploy', { type, id });
            state.gameArt = out2.art;
            const saved = await gameSave(true);
            msg += saved ? ', deployed and saved to the game.'
              : ', deployed — but the card data could not be saved (see the validation error).';
          } else {
            msg += ' — deploy when ready.';
          }
          toast(msg, 'ok');
          renderSidePanels();
        };
        rowEl.append(el('div', { style: 'width:224px' },
          el('img', { src, loading: 'lazy',
            title: caption + ' — click to inspect full-size',
            style: 'width:224px; height:auto; border-radius:6px; cursor:zoom-in',
            onclick: () => openLightbox(src, caption, pick) }),
          el('div', {},
            el('span', { class: 'subtle', style: 'font-size:11px; margin-right:6px', text: caption }),
            el('button', { class: 'ghost tiny', text: '✔ use', title: 'Set as the workspace art (deploy separately)', onclick: async e => {
              e.target.disabled = true;
              try { await pick(); } catch (err) { toast(err.message, 'err'); }
              e.target.disabled = false;
            } }),
            el('button', { class: 'ghost tiny', text: '⬆ to game', title: 'Set as the card art AND deploy it into the game assets in one step', onclick: async e => {
              e.target.disabled = true;
              try { await pick(true); } catch (err) { toast(err.message, 'err'); }
              e.target.disabled = false;
            } }))));
      }
      gallery.append(rowEl);
    }
  };

  let runBtn = null;
  const stopBtn = el('button', { class: 'ghost', text: '✕ Stop', disabled: true,
    title: 'Stop this flow now — aborts the in-flight image, keeps what already landed' });
  const attach = jobId => {
    if (runBtn) { runBtn.disabled = true; runBtn.textContent = '⛓ Running…'; }
    stopBtn.disabled = false;
    stopBtn.onclick = async () => {
      stopBtn.disabled = true;
      try {
        await api('/api/art/flow-stop', { id: jobId });
        toast('Stopping…', 'ok');
      } catch (e) { toast(e.message, 'err'); }
    };
    const tick = async () => {
      if (!document.body.contains(gallery)) return;   // modal closed — server keeps going; reopening reattaches
      let j;
      try { j = await api('/api/art/flow-job?id=' + jobId); }
      catch (e) { setTimeout(tick, 4000); return; }
      renderGallery(j.nodes);
      if (j.status === 'running' || j.status === 'queued') {
        status.className = 'art-status';
        status.textContent = j.status === 'queued'
          ? 'Queued — waiting for the current job to finish…'
          : `Running — step ${j.stepNow}/${j.stepCount}, image ${j.done + 1} of ${j.total} (${j.elapsed}s)…`;
        setTimeout(tick, 2500);
        return;
      }
      if (runBtn) { runBtn.disabled = false; runBtn.textContent = '⛓ Run flow'; }
      stopBtn.disabled = true;
      status.className = j.status === 'error' ? 'art-status err' : 'art-status';
      status.textContent = j.status === 'error' ? 'Flow failed: ' + j.error
        : j.status === 'stopped' ? `Stopped — ${j.done} images landed; click any to use it.`
        : `Done — ${j.done} images in ${j.elapsed}s. Click a candidate to use it.`;
      renderSidePanels();
    };
    tick();
  };

  runBtn = el('button', { class: 'primary', text: '⛓ Run flow', onclick: async () => {
    if (flowStepsTotal(cfg) > 24) { toast('Over the 24-image cap — trim the sample counts.', 'err'); return; }
    const a = artDraft();
    await saveStyleNow();
    const base = a.prompt || EDITORS[type].promptFor(state.draft);
    const style = (state.settings.artStyle || '').trim();
    currentPrompt = style ? base + ', ' + style : base;
    try {
      const anchor = anchorCfg.source === 'none' ? undefined
        : {
          source: anchorCfg.source,   // 'canonical' resolves server-side (mandatory)
          path: anchorCfg.source === 'game' ? a.refGameArt
            : anchorCfg.source === 'upload' ? a.refUpload : undefined,
        };
      const out = await api('/api/art/flow', { type, id, prompt: currentPrompt,
        negative: a.negative || '', steps: cfg.map(st => Object.assign({}, st)), anchor });
      gallery.replaceChildren();
      attach(out.jobId);
      kickQueue();
    } catch (e) { toast(e.message, 'err'); }
  } });

  const modal = el('div', { class: 'modal', style: 'width:820px; max-height:86vh; overflow-y:auto' },
    // pinned header: the title + ✕ ride together at the top of the (scrolling) modal, so the
    // close button is always reachable and never overlaps the title.
    el('div', { class: 'modal-header' },
      el('h2', {}, '⛓ Multi-step generation — ', el('span', { class: 'subtle', text: id })),
      el('button', { class: 'modal-x', title: 'Close', onclick: () => $('modal-root').replaceChildren() }, '✕')),
    el('div', { class: 'hint', text: 'Each step feeds every one of its outputs into the next; sample counts multiply. '
      + 'The item\'s prompt (+ shared style) drives all steps; background removal happens on the picked image only.' }),
    el('div', { class: 'frow', style: 'margin:8px 0' },
      fld('Anchor (step-1 input image)', anchorSelWrap,
        'the concept image the whole tree grows from — step-1 denoise is your adherence dial'),
      el('div', { class: 'fld' },
        el('span', { class: 'lab', text: '…or upload an anchor' }),
        el('input', { type: 'file', accept: 'image/*', onchange: async e => {
          const f = e.target.files && e.target.files[0];
          if (!f) return;
          try {
            const dataUrl = await new Promise((ok, bad) => {
              const rd = new FileReader();
              rd.onload = () => ok(rd.result);
              rd.onerror = () => bad(new Error('reading the file failed'));
              rd.readAsDataURL(f);
            });
            const out = await api('/api/art/upload-ref', { name: f.name, dataBase64: dataUrl.split(',')[1] });
            a0.refUpload = out.name;
            a0.refUploadLabel = f.name;
            anchorCfg.source = 'upload';
            rebuildAnchorSel();
            renderSteps();
            toast(`Anchor uploaded: ${f.name}`, 'ok');
          } catch (err) { toast('Upload failed: ' + err.message, 'err'); }
        } }))),
    el('div', { class: 'frow', style: 'margin:8px 0' },
      el('div', { class: 'fld wide' },
        el('span', { class: 'lab' }, 'Flow presets ',
          ...presetControls('flowPresets', () => JSON.stringify(cfg),
            v => {
              try {
                const s = JSON.parse(v);
                if (Array.isArray(s) && s.length) { cfg.length = 0; cfg.push(...s); renderSteps(); }
              } catch (e) { toast('Unreadable preset.', 'err'); }
            })))),
    stepsWrap,
    el('button', { class: 'ghost tiny', text: '＋ add step', onclick: () => {
      cfg.push({ model: 'krea2', samples: 1, denoise: 0.55 });
      renderSteps();
    } }),
    totalLine,
    el('div', { class: 'modal-actions', style: 'justify-content:flex-start' },
      runBtn,
      stopBtn,
      el('button', { class: 'ghost', text: '★ Quick Flow',
        title: 'Appoint THIS flow (steps + anchor policy) as the Quick Flow — then one click runs it '
          + 'per card or per file from the list, auto-picking a random last-step image as the art',
        onclick: async () => {
          const policyMap = { none: 'none', current: 'current', canonical: 'canonical', game: 'custom', upload: 'none' };
          const policy = policyMap[anchorCfg.source] || 'custom';
          const qf = { steps: cfg.map(st => Object.assign({}, st)), anchor: policy };
          try {
            await api('/api/settings', { quickFlow: qf });
            state.settings.quickFlow = qf;
            toast('Quick Flow appointed: ' + quickFlowSummary(qf)
              + (anchorCfg.source === 'upload' ? ' (uploads can\'t batch — anchor policy set to none)' : ''), 'ok');
          } catch (e) { toast(e.message, 'err'); }
        } }),
      el('button', { class: 'ghost', text: 'Close', onclick: () => $('modal-root').replaceChildren() })),
    status,
    gallery,
  );
  $('modal-root').replaceChildren(modal);

  // reattach to a running flow, else show the item's last finished flow
  const running = (state.flowJobsList || []).find(j => j.type === type && j.itemId === id);
  if (running) attach(running.id);
  else api(`/api/art/flow-result?type=${type}&id=${id}`).then(out => {
    if (out.result && out.result.nodes) {
      currentPrompt = out.result.prompt || '';
      renderGallery(out.result.nodes);
      status.textContent = `Showing the last flow (${out.result.at ? out.result.at.slice(0, 10) : 'earlier'}) — click a candidate to use it.`;
    }
  }).catch(() => {});
}

// ── settings & health ────────────────────────────────────────────────────────
async function checkComfy() {
  const badge = $('comfy-badge');
  try {
    const h = await api('/api/comfy/health');
    if (h.ok) { badge.className = 'badge ok'; badge.textContent = 'ComfyUI: connected (' + (h.version || '?') + ')'; }
    else { badge.className = 'badge bad'; badge.textContent = 'ComfyUI: unreachable'; badge.title = h.error || ''; }
  } catch (e) {
    badge.className = 'badge bad'; badge.textContent = 'ComfyUI: unreachable';
  }
}

async function openSettings() {
  const s = {
    comfyUrl: state.settings.comfyUrl,
    audiogenUrl: state.settings.audiogenUrl || 'http://127.0.0.1:8188',
    turboLora: state.settings.turboLora || '',
    turboSteps: state.settings.turboSteps || 8,
    turboStrength: state.settings.turboStrength == null ? 1.0 : state.settings.turboStrength,
    llmProvider: state.settings.llmProvider || 'ollama',
    ollamaUrl: state.settings.ollamaUrl || 'http://127.0.0.1:11434',
    llmModel: state.settings.llmModel || 'gemma4:31b',
    effectsModel: state.settings.effectsModel || 'qwen3-coder-next:q4_K_M',
    claudeModel: state.settings.claudeModel || 'claude-opus-4-8',
    openaiModel: state.settings.openaiModel || 'gpt-5.5',
    claudeCodeModel: state.settings.claudeCodeModel || '',
  };
  const loraInput = textInput(s, 'turboLora', () => {}, 'a .safetensors under models/loras');
  loraInput.setAttribute('list', 'lora-list');
  const loraList = el('datalist', { id: 'lora-list' });
  const modal = el('div', { class: 'modal' },
    el('h2', { text: 'Settings' }),
    fld('ComfyUI server URL', textInput(s, 'comfyUrl', () => {}, 'http://127.0.0.1:8187')),
    el('div', { class: 'hint', style: 'margin:8px 0 14px', text: 'The Flux 2 dev workflow needs flux2_dev_fp8mixed / mistral_3_small_flux2 / flux2-vae on that server.' }),
    fld('AudioGen server URL', textInput(s, 'audiogenUrl', () => {}, 'http://127.0.0.1:8188'), 'local SFX generator (tools/audiogen/start_server.bat) for the Sounds tab'),
    fld('Turbo LoRA', loraInput, 'used when ⚡ Turbo is checked in the art panel; type to search the server’s LoRAs'),
    loraList,
    el('div', { class: 'frow', style: 'margin-top:10px' },
      fld('Turbo steps', numInput(s, 'turboSteps', () => {}, { min: 1 }), 'default steps in turbo mode', 'narrow'),
      fld('Turbo strength', numInput(s, 'turboStrength', () => {}, { float: true, step: 0.05, min: 0, max: 2 }), null, 'narrow'),
    ),
    fld('✨ AI provider', selectInput(s, 'llmProvider', [
      { value: 'ollama', label: 'Local (Ollama)' },
      { value: 'claude-code', label: 'Claude Code (your subscription)' },
      { value: 'claude', label: 'Claude API (pay per token)' },
      { value: 'openai', label: 'ChatGPT (OpenAI API, pay per token)' },
    ], () => {}), 'routes ALL ✨ features — art prompts, prompt-from-art, effects from words'),
    el('div', { class: 'frow', style: 'margin-top:10px' },
      fld('Ollama URL', textInput(s, 'ollamaUrl', () => {}, 'http://127.0.0.1:11434'), 'local LLM server for the ✨ features'),
      fld('LLM model', textInput(s, 'llmModel', () => {}, 'gemma4:31b'), 'vision model for ✨ art prompts'),
      fld('Effects model', textInput(s, 'effectsModel', () => {}, 'qwen3-coder-next:q4_K_M'), 'coder model for ✨ effects from words'),
    ),
    el('div', { class: 'frow', style: 'margin-top:10px' },
      fld('Claude Code model', textInput(s, 'claudeCodeModel', () => {}, '(your Claude Code default)'), 'uses the `claude` CLI login — no key; blank = its default, or opus/sonnet/haiku'),
      fld('Claude API model', textInput(s, 'claudeModel', () => {}, 'claude-opus-4-8'), 'auth: `ant auth login` or ANTHROPIC_API_KEY'),
      fld('ChatGPT model', textInput(s, 'openaiModel', () => {}, 'gpt-5.5'), 'auth: OPENAI_API_KEY env var'),
    ),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Cancel', onclick: () => $('modal-root').replaceChildren() }),
      el('button', { class: 'primary', text: 'Save', onclick: async () => {
        try {
          const out = await api('/api/settings', s);
          state.settings = out.settings;
          $('modal-root').replaceChildren();
          toast('Settings saved.', 'ok');
          checkComfy();
          if (state.draft) renderSidePanels();
        } catch (e) { toast(e.message, 'err'); }
      } }),
    ));
  $('modal-root').replaceChildren(modal);
  // fill the LoRA datalist from the server (async, best-effort)
  try {
    const { loras } = await api('/api/comfy/loras');
    for (const l of loras || []) loraList.append(el('option', { value: l }));
  } catch (e) { /* offline — free text still works */ }
}

// ── generation queue monitor (bottom-right widget) ───────────────────────────
// A single always-on poller drives a fixed panel listing every generation request —
// running, queued behind it, and recently finished. It reads the server's /api/art/queue
// (the authoritative FIFO); the per-flow strips/modals stay as the drill-in detail views.
let queuePollTimer = null;
let queueCollapsed = false;
const QUEUE_ICON = { queued: '⧗', running: '▶', done: '✓', error: '✕', stopped: '■' };

// Poll now — called on boot and after anything is enqueued, so the widget appears at once.
function kickQueue() {
  if (queuePollTimer) { clearTimeout(queuePollTimer); queuePollTimer = null; }
  pollQueue();
}

async function pollQueue() {
  let list = [];
  try { list = (await api('/api/art/queue')).queue || []; }
  catch (e) { /* server hiccup — keep the last render, retry on the timer */ }
  renderQueueWidget(list);
  const active = list.some(e => e.status === 'queued' || e.status === 'running');
  queuePollTimer = setTimeout(pollQueue, active ? 1500 : 5000);
}

function queueProgressText(e) {
  const pr = e.progress || {};
  if (e.status === 'queued') return 'waiting…';
  if (e.status === 'error') return e.error || 'failed';
  if (e.status === 'stopped') return 'stopped';
  if (e.status === 'done') return 'done';
  if (e.kind === 'flow-batch') {
    if (pr.phase === 'recipes') return `filling recipes ${pr.done || 0}/${pr.total || '?'}`;
    return `card ${Math.min((pr.done || 0) + 1, pr.total || 1)}/${pr.total || '?'}`
      + (pr.currentId ? ' · ' + pr.currentId : '');
  }
  if (e.kind === 'flow') return `step ${pr.stepNow || 0}/${pr.stepCount || '?'} · ${pr.done || 0}/${pr.total || '?'} imgs`;
  if (e.kind === 'recipe-batch') return `recipe ${Math.min((pr.done || 0) + 1, pr.total || 1)}/${pr.total || '?'}`;
  if (e.kind === 'prompt') return `writing… ${pr.elapsed || 0}s`;
  return `${pr.elapsed || 0}s`;
}

function renderQueueWidget(list) {
  let w = document.getElementById('queue-widget');
  if (!list.length) { if (w) w.remove(); return; }
  if (!w) { w = el('div', { id: 'queue-widget' }); document.body.append(w); }
  const active = list.filter(e => e.status === 'queued' || e.status === 'running');
  const done = list.filter(e => e.status !== 'queued' && e.status !== 'running');
  const pending = active.filter(e => e.status === 'queued').length;
  const header = el('div', { class: 'q-head' },
    el('span', { class: 'q-title', text: `⧗ Queue${pending ? ' · ' + pending + ' waiting' : (active.length ? ' · running' : '')}` }),
    el('div', { class: 'q-head-btns' },
      pending > 1 ? el('button', { class: 'ghost tiny', text: 'clear queued',
        onclick: () => queueClear('pending') }) : null,
      done.length ? el('button', { class: 'ghost tiny', text: 'clear done',
        onclick: () => queueClear('history') }) : null,
      el('button', { class: 'ghost tiny', text: queueCollapsed ? '▸' : '▾', title: 'collapse',
        onclick: () => { queueCollapsed = !queueCollapsed; renderQueueWidget(list); } })));
  const rowFor = e => el('div', { class: 'q-row q-' + e.status },
    el('span', { class: 'q-ico', text: QUEUE_ICON[e.status] || '•' }),
    el('div', { class: 'q-body' },
      el('div', { class: 'q-label', text: e.label, title: e.label }),
      el('div', { class: 'q-sub' + (e.status === 'error' ? ' err' : ''), text: queueProgressText(e) })),
    // Quick Flow batches get a live monitor (candidates as they land) while active
    (e.kind === 'flow-batch' && e.file && (e.status === 'running' || e.status === 'queued'))
      ? el('button', { class: 'ghost tiny q-x', text: '👁', title: 'Monitor this batch',
          onclick: () => openFlowBatchMonitor(e.file) }) : null,
    el('button', { class: 'ghost tiny q-x', text: '✕',
      title: e.status === 'running' ? 'Stop now (aborts the in-flight image)' : 'Remove from queue',
      onclick: async () => {
        try { await api('/api/art/queue-remove', { id: e.id }); kickQueue(); }
        catch (err) { toast(err.message, 'err'); }
      } }));
  const listWrap = el('div', { class: 'q-list' });
  if (!queueCollapsed) {
    for (const e of active) listWrap.append(rowFor(e));
    for (const e of done.slice().reverse()) listWrap.append(rowFor(e));
  }
  w.replaceChildren(header, listWrap);
}

async function queueClear(which) {
  try { await api('/api/art/queue-clear', { which }); kickQueue(); }
  catch (e) { toast(e.message, 'err'); }
}

// ── 💬 edit chat: conversational blanket edits ────────────────────────────────
// Talk to an LLM about the game's content; it answers with an ops plan the server
// simulates + validates into a per-entry before/after PREVIEW. Nothing is written
// until Apply — each applied entry then has the normal per-entry Revert. The
// conversation lives in state.chat, so closing/reopening the modal keeps it.
function openChatModal() {
  if (!state.chat) state.chat = { log: [], busy: false };
  renderChatModal();
}

// History as the server wants it: assistant turns replay the exact JSON they proposed,
// so follow-ups ("also make them cost 2") have the prior plan in context.
function chatHistoryPayload() {
  return state.chat.log
    .filter(m => !m.failed)
    .map(m => ({ role: m.role,
      content: m.role === 'assistant' ? JSON.stringify({ reply: m.reply || '', ops: m.ops || [] }) : m.text }));
}

function renderChatMsg(m) {
  if (m.role === 'user') return el('div', { class: 'chat-msg user', text: m.text });
  const parts = [];
  if (m.reply) parts.push(el('div', { class: 'chat-reply', text: m.reply }));
  if (m.warning) parts.push(el('div', { class: 'chat-warning', text: '⚠ ' + m.warning }));
  if (m.changes && m.changes.length) {
    const list = el('div', { class: 'chat-changes' },
      m.changes.map(c => el('div', { class: 'chat-change' },
        el('b', { text: `${c.type}/${c.id}` }),
        c.created ? el('span', { class: 'chat-new', text: 'NEW' }) : null,
        el('span', { class: 'subtle', text: ' · ' + c.file }),
        (c.notes || []).map(n => el('div', { class: 'chat-note', text: n })))));
    parts.push(list);
    if (m.applyResult) {
      const a = m.applyResult;
      parts.push(el('div', { class: 'chat-applied', text: `✔ applied ${a.applied.length}`
        + (a.skipped.length ? ` — skipped ${a.skipped.map(x => `${x.entry} (${x.error})`).join(', ')}` : '') }));
    } else {
      parts.push(el('button', { class: 'primary', text: `Apply ${m.changes.length} ${m.changes.length === 1 ? 'entry' : 'entries'}`,
        disabled: state.chat.busy, onclick: () => applyChatChanges(m) }));
    }
  }
  return el('div', { class: 'chat-msg assistant' }, parts.length ? parts : el('div', { class: 'subtle', text: '(empty reply)' }));
}

function renderChatModal() {
  const c = state.chat;
  const logEl = el('div', { class: 'chat-log' }, c.log.map(renderChatMsg));
  if (c.busy) logEl.append(el('div', { class: 'chat-msg assistant chat-busy', text: '… thinking' }));
  if (!c.log.length) logEl.append(el('div', { class: 'empty-hint', style: 'margin:auto; text-align:center' },
    el('p', { text: 'Ask for blanket edits in plain words — "all pawns cost 2 mana, water pawns get +2 health" — or just ask questions about the content.' })));
  const input = el('textarea', { class: 'chat-input', rows: 2, placeholder: 'Describe the change… (Enter sends, Shift+Enter = newline)',
    value: c.pending || '',
    oninput: e => { c.pending = e.target.value; },
    onkeydown: e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); } } });
  const modal = el('div', { class: 'modal chat-modal' },
    el('div', { class: 'modal-header' },
      el('h2', {}, '💬 AI blanket edits'),
      el('button', { class: 'ghost tiny', text: 'Clear chat', disabled: c.busy,
        onclick: () => { state.chat = { log: [], busy: false }; renderChatModal(); } }),
      el('button', { class: 'modal-x', title: 'Close (keeps the conversation)', onclick: () => $('modal-root').replaceChildren() }, '✕')),
    el('div', { class: 'hint', text: 'Proposed edits preview here and touch nothing until you press Apply. '
      + 'Applied entries get the normal per-entry Revert in their editors.' }),
    logEl,
    el('div', { class: 'chat-send-row' }, input,
      el('button', { class: 'primary', text: 'Send', disabled: c.busy, onclick: sendChat })));
  $('modal-root').replaceChildren(modal);
  logEl.scrollTop = logEl.scrollHeight;
  input.focus();
}

async function sendChat() {
  const c = state.chat;
  const text = (c.pending || '').trim();
  if (!text || c.busy) return;
  c.log.push({ role: 'user', text });
  c.pending = '';
  c.busy = true;
  renderChatModal();
  try {
    const r = await api('/api/chat/edit', { messages: chatHistoryPayload() });
    c.log.push({ role: 'assistant', reply: r.reply, ops: r.ops || [], changes: r.changes || [], warning: r.warning });
  } catch (e) {
    // failed turns stay visible but are excluded from the replayed history
    c.log.push({ role: 'assistant', reply: '', failed: true, warning: e.message });
  }
  c.busy = false;
  renderChatModal();
}

async function applyChatChanges(m) {
  const c = state.chat;
  if (c.busy) return;
  c.busy = true;
  renderChatModal();
  try {
    const r = await api('/api/chat/apply', { changes: m.changes });
    m.applyResult = r;
    toast(r.skipped.length ? `Applied ${r.applied.length}, skipped ${r.skipped.length}.` : `Applied ${r.applied.length} entries.`,
      r.skipped.length ? 'err' : undefined);
    await refreshState(true);
  } catch (e) { toast(e.message, 'err'); }
  c.busy = false;
  renderChatModal();
}

// ── boot ─────────────────────────────────────────────────────────────────────
$('new-item-btn').addEventListener('click', newItem);
$('gen-set-btn').addEventListener('click', openSetGenerator);
$('bulk-edit-btn').addEventListener('click', openBulkEditor);
$('save-btn').addEventListener('click', gameSave);
$('revert-btn').addEventListener('click', gameRevert);
$('enabled-check').addEventListener('change', e => {
  if (!state.draft) return;
  state.draft.enabled = e.target.checked;
  onDraftChange();
  refreshInstallBar();
});
$('delete-btn').addEventListener('click', deleteItem);
$('settings-btn').addEventListener('click', openSettings);
$('chat-btn').addEventListener('click', openChatModal);
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && state.advancedOpen) closeAdvanced();
});
$('copy-json').addEventListener('click', () => {
  navigator.clipboard.writeText($('json-preview').textContent);
  toast('JSON copied.');
});
window.addEventListener('beforeunload', e => { if (state.dirty) e.preventDefault(); });

refreshState().then(checkComfy).catch(e => toast('Failed to load: ' + e.message, 'err'));
setInterval(checkComfy, 30000);
pollQueue();   // the generation-queue monitor widget
