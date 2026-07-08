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
// list's kin bar (renderKinBar) and read by every ✨ action — the per-card quick button,
// the per-file batch, and the art panel dial. Changing it anywhere changes it everywhere.
const KIN_MODES = [
  { value: 'concept', label: 'Same concept — the design: same recognizable character, fresh pose & scene' },
  { value: 'replicate', label: 'Replicate — the picture: same pose & framing, re-themed only' },
  { value: 'free', label: 'Free — just the idea: loose family blend' },
];
function kinDefault() { return state.settings.kinAdherence || 'concept'; }
function kinAnchorMode() { return state.settings.kinAnchorMode || 'current'; }
function kinThemeMode() { return state.settings.kinThemeMode || 'family'; }
function kinThemeRefs() { return state.settings.kinThemeRefs || (state.settings.kinThemeRefs = []); }
// The ✨ kin controls are ONE global source of truth: every setter persists and refreshes
// the list so all three entry points (per-card quick, per-file batch, editor) read the same.
function setKinField(key, v) {
  state.settings[key] = v;
  const patch = {}; patch[key] = v;
  api('/api/settings', patch).catch(() => {});
  renderItemList();
}
function setKinDefault(v) { setKinField('kinAdherence', v); }
function toggleThemeRef(id) {
  const refs = kinThemeRefs().slice();
  const i = refs.indexOf(id);
  if (i >= 0) refs.splice(i, 1); else refs.push(id);
  setKinField('kinThemeRefs', refs);
}

const KIN_ANCHOR_MODES = [
  { value: 'current', label: 'Prioritize current art concept — regenerate off the card\'s own art if it has any' },
  { value: 'base', label: 'Prioritize base unit art concept — always anchor on the base unit, ignore own art' },
];
const KIN_THEME_MODES = [
  { value: 'family', label: 'Infer theme from unit family — auto element-relatives' },
  { value: 'select', label: 'Select theme references — hand-pick the cards below' },
];

// The visible kin controls above the card list — all global, cards only.
function renderKinBar() {
  const bar = $('kin-bar');
  if (!bar) return;
  if (state.currentType !== 'card') { bar.hidden = true; bar.replaceChildren(); return; }
  bar.hidden = false;
  const selecting = kinThemeMode() === 'select';
  // NOTE: native replaceChildren coerces a null arg to the string "null" — unlike el(),
  // it does not skip nulls. Build the list and filter before spreading.
  const parts = [
    el('span', { class: 'lab', text: '✨ kin default' }),
    selectInput({ get v() { return kinDefault(); }, set v(x) { setKinDefault(x); } }, 'v', KIN_MODES, () => {}),
    selectInput({ get v() { return kinAnchorMode(); }, set v(x) { setKinField('kinAnchorMode', x); } }, 'v', KIN_ANCHOR_MODES, () => {}),
    selectInput({ get v() { return kinThemeMode(); }, set v(x) { setKinField('kinThemeMode', x); } }, 'v', KIN_THEME_MODES, () => {}),
    selecting ? el('div', { class: 'kin-refs-row' },
      el('span', { class: 'hint', text: `${kinThemeRefs().length} theme reference(s) selected — tick "use as reference" on cards below` }),
      el('button', { class: 'ghost tiny', text: 'Clear all', disabled: !kinThemeRefs().length,
        onclick: () => setKinField('kinThemeRefs', []) })) : null,
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
  bar.replaceChildren(...parts);
}
function artGuidesEnabled() { return !!state.settings.useArtGuides; }

// ── ✨ art guides editor ──────────────────────────────────────────────────────
// Composition-keyed authored direction (tool-bound). Loaded fresh, edited as row arrays,
// saved back wholesale — the server normalizes keys to canonical sorted order.
function openArtGuidesModal() {
  api('/api/art-guides').then(res => {
    const guides = (res && res.guides) || { concept: {}, theme: {} };
    const rows = { concept: [], theme: [] };
    for (const axis of ['concept', 'theme'])
      for (const [k, v] of Object.entries(guides[axis] || {}))
        rows[axis].push({ key: k, label: v.label || '', positive: v.positive || '', negative: v.negative || '' });
    renderArtGuidesModal(rows);
  }).catch(err => toast('Could not load art guides: ' + err.message, 'err'));
}

function renderArtGuidesModal(rows) {
  const meta = {
    concept: { title: 'Concept guides — keyed by PIECE composition', hint: 'e.g. bishop_bishop (Hierophant)' },
    theme: { title: 'Theme guides — keyed by ELEMENT composition', hint: 'e.g. air_fire (Lightning)' },
  };
  const section = axis => {
    const wrap = el('div', { class: 'guide-section' }, el('h3', { text: meta[axis].title }));
    for (const row of rows[axis]) {
      wrap.append(el('div', { class: 'guide-row' },
        el('div', { class: 'frow' },
          fld('Composition key', textInput(row, 'key', () => {}, meta[axis].hint), 'order is normalized on save'),
          fld('Label', textInput(row, 'label', () => {}, axis === 'concept' ? 'Hierophant' : 'Lightning')),
          el('button', { class: 'ghost tiny', text: '✕', title: 'delete this guide',
            onclick: () => { rows[axis] = rows[axis].filter(r => r !== row); renderArtGuidesModal(rows); } })),
        el('label', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Positive — authoritative direction' }),
          el('textarea', { value: row.positive, oninput: e => { row.positive = e.target.value; } })),
        el('label', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Negative — anti-drift (do NOT depict)' }),
          el('textarea', { value: row.negative, oninput: e => { row.negative = e.target.value; } }))));
    }
    wrap.append(el('button', { class: 'ghost', text: '+ Add ' + axis + ' guide',
      onclick: () => { rows[axis].push({ key: '', label: '', positive: '', negative: '' }); renderArtGuidesModal(rows); } }));
    return wrap;
  };
  $('modal-root').replaceChildren(el('div', { class: 'modal', style: 'width:720px; max-height:86vh; overflow:auto' },
    el('h2', {}, '✨ Art guides'),
    el('div', { class: 'hint', text: 'Authored art direction injected into every ✨ writer when "use art guides" is on. '
      + 'Exact-composition match; positives are authoritative, negatives push drift away.' }),
    section('concept'), section('theme'),
    el('div', { class: 'modal-actions' },
      el('button', { class: 'ghost', text: 'Cancel', onclick: () => $('modal-root').replaceChildren() }),
      el('button', { class: 'primary', text: 'Save', onclick: async () => {
        const payload = { concept: {}, theme: {} };
        for (const axis of ['concept', 'theme'])
          for (const row of rows[axis]) {
            const key = (row.key || '').trim();
            if (!key) continue;
            payload[axis][key] = { label: row.label || '', positive: row.positive || '', negative: row.negative || '' };
          }
        try {
          await api('/api/art-guides', payload);
          $('modal-root').replaceChildren();
          toast('Art guides saved', 'ok');
        } catch (err) { toast('Save failed: ' + err.message, 'err'); }
      } }))));
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
        'anchor = the card\'s own art, else its bare piece version\'s art — remembered as the default')),
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
  return qf.steps.map(st => `${(state.artModels[st.model] || { label: st.model }).label}×${st.samples}`
    + (st.denoise ? `@${st.denoise}` : '') + (st.turbo ? '⚡' : '')).join(' → ')
    + ` · anchor: ${qf.anchor || 'recipe'}`;
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
      if (j.status === 'running') {
        renderItemList();
        renderBatchStrip();
        setTimeout(poll, 2000);
        return;
      }
      delete state.flowBatchRuns[file];
      renderBatchStrip();
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

// A fixed strip (bottom-left) that exists whenever a quick-flow batch runs — the
// always-visible answer to "is anything happening, and on which card?"
function renderBatchStrip() {
  let strip = document.getElementById('batch-strip');
  const runs = Object.entries(state.flowBatchRuns || {});
  if (!runs.length) { if (strip) strip.remove(); return; }
  if (!strip) {
    strip = el('div', { id: 'batch-strip',
      style: 'position:fixed; left:12px; bottom:12px; z-index:1500; display:flex; flex-direction:column; gap:6px' });
    document.body.append(strip);
  }
  strip.replaceChildren(...runs.map(([file, run]) => {
    const j = run.snapshot || {};
    const cf = j.currentFlow;
    const text = `⛓ ${file} — ` + (j.phase === 'recipes'
      ? `filling recipes ${j.done || 0}/${j.total || '?'}${j.currentId ? ': ' + j.currentId : ''}`
      : `card ${Math.min((j.done || 0) + 1, j.total || 1)}/${j.total || '?'}${j.currentId ? ': ' + j.currentId : ''}`
        + (cf ? ` · image ${Math.min(cf.done + 1, cf.total)}/${cf.total}` : ''));
    return el('div', { style: 'background:#1d2030; border:1px solid #3a3f58; border-radius:8px; '
        + 'padding:8px 10px; display:flex; align-items:center; gap:10px; font-size:13px; color:#dde4f5' },
      el('span', { text }),
      el('button', { class: 'ghost tiny', text: '👁 monitor', onclick: () => openFlowBatchMonitor(file) }),
      el('button', { class: 'ghost tiny', text: '✕', title: 'Stop now (aborts the in-flight image too)',
        onclick: async () => {
          try {
            await api('/api/art/flow-batch-stop', { id: run.jobId });
            toast('Stopping…', 'ok');
          } catch (e) { toast(e.message, 'err'); }
        } }));
  }));
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
    const running = j.status === 'running';
    stopBtn.disabled = !running;
    if (running && j.phase === 'recipes') {
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

// The bulk engagement: eligibility counts, the fill-missing-recipes offer, then run.
function openQuickFlowBatchModal(file, entries) {
  const qf = state.settings.quickFlow;
  const withRecipe = entries.filter(g => g.recipe).length;
  const missing = entries.length - withRecipe;
  const cfg = { fill: missing > 0, adherence: kinDefault() };
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
          const out = await api('/api/art/flow-batch', { type: 'card', file, fill: cfg.fill, adherence: cfg.adherence });
          attachFlowBatchPoll(file, out.jobId);
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
      if (j.status === 'running') {
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
const TAB_ORDER = ['card', 'relic', 'status', 'ability', 'charm', 'upgrade', 'encounter', 'nodeweights'];
const TAB_LABELS = { card: '🃏 Cards', relic: '🏺 Relics', status: '☠ Statuses', ability: '✨ Abilities',
  charm: '🔮 Charms', upgrade: '🌳 Upgrades', encounter: '⚔ Encounters', nodeweights: '🗺 Map Nodes' };

function renderTabs() {
  const tabs = $('type-tabs');
  tabs.replaceChildren();
  for (const t of TAB_ORDER) {
    tabs.append(el('button', {
      class: state.currentType === t ? 'active' : '',
      text: TAB_LABELS[t] || t,
      onclick: () => { if (!confirmDiscard()) return; state.currentType = t; state.currentId = null; state.draft = null; renderTabs(); renderItemList(); renderEditor(); },
    }));
  }
}

function renderItemList() {
  $('item-list-title').textContent = state.types[state.currentType] ? state.types[state.currentType].label + 's' : '';
  $('gen-set-btn').hidden = state.currentType !== 'card';
  renderKinBar();
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
  const q = state.gameFilter.trim().toLowerCase();
  const filtered = q ? gameItems.filter(g => g.id.includes(q) || (g.name || '').toLowerCase().includes(q)) : gameItems;

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
    const expanded = q ? true : (expandState[file] != null ? expandState[file] : holdsCurrent);
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
    const batchRun = state.flowBatchRuns && state.flowBatchRuns[file];
    for (const g of entries) {
      // recipe marker: stored on the entry, or landed just now by the running batch
      const hasRecipe = g.recipe || (run && run.doneIds.has(g.id));
      list.append(el('div', {
        class: 'item-row tree-leaf' + (state.mode === 'game' && state.currentId === g.id ? ' active' : ''),
        onclick: () => {
          if (!confirmDiscard()) return;
          openGameItem(g.id);
        },
      },
        g.art ? el('img', { class: 'thumb', loading: 'lazy', src: '/gameart/' + g.art }) : null,
        el('div', { class: 'item-name' }, el('div', { text: g.name }), el('div', { class: 'item-id', text: g.id })),
        // theme-reference picker — only in "Select theme references" mode
        (state.currentType === 'card' && kinThemeMode() === 'select')
          ? el('label', { class: 'check ref-check', title: 'Use as a theme reference for ✨ kin inference',
              onclick: e => e.stopPropagation() },
              el('input', { type: 'checkbox', checked: kinThemeRefs().includes(g.id),
                onchange: () => toggleThemeRef(g.id) }), 'ref')
          : null,
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
        // one-click Quick Flow: recipe-carrying cards only (the recipe prompt IS the flow prompt)
        (state.currentType === 'card' && hasRecipe && !run && !batchRun) ? el('button', { class: 'ghost tiny', text: '⛓',
          title: `Run the Quick Flow on THIS card — one image from the last step is picked at random as its art`
            + (state.settings.quickFlow ? ` (${quickFlowSummary(state.settings.quickFlow)})` : ' — none appointed yet'),
          onclick: async e => {
            e.stopPropagation();
            const btn = e.target;
            btn.disabled = true; btn.textContent = '…';
            try {
              const out = await api('/api/art/flow-batch', { type: 'card', ids: [g.id], fill: false });
              attachFlowBatchPoll(g.file, out.jobId);
              renderItemList();
              openFlowBatchMonitor(g.file);
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
  const empty = $('editor-empty'), body = $('editor-body');
  if (!state.draft) { empty.hidden = false; body.hidden = true; return; }
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
async function gameSave() {
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
    toast(`Saved into ${out.file}` + (out.art ? ' (+ art)' : ''), 'ok');
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
                });
                a.prompt = out.prompt; promptArea.value = out.prompt; noChange();
              } catch (err) { toast('LLM prompt failed: ' + err.message, 'err'); }
              btn.disabled = false; btn.textContent = '✨ llm';
            } }),
          state.currentType === 'card' ? el('button', { class: 'ghost tiny', text: '✨ kin',
            disabled: state.isNew || !state.currentId,
            title: 'Infer the prompt from this card\'s FAMILY: the anchor image (own art, else the '
              + 'bare piece version) is the concept, element-relatives give the theme; the anchor '
              + `becomes the generation reference. Adherence = the global kin default (${kinDefault()}).`,
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
            'the anchor = own art, else the bare piece version\'s art'))
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
          toast(`Deployed to ${out2.art} (give the Godot editor focus once to import it).`, 'ok');
          state.gameArt = out2.art;
          renderSidePanels();
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
  const style = last ? (last.style || '') : (state.settings.artStyle || '').trim();
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
    if (j.status === 'running') {
      if (state.currentId === state.artJob.itemId) {
        // both views (compact panel and the advanced modal) show a live status line
        for (const s of document.querySelectorAll('.art-status'))
          s.textContent = `Generating… ${j.elapsed}s`;
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
      grid.append(el('div', { style: 'width:224px' },
        el('img', { src, loading: 'lazy', style: 'width:224px; height:auto; border-radius:6px; cursor:zoom-in',
          onclick: () => openLightbox(src, `#${entry.n} · ${meta}`, use) }),
        el('div', { class: 'subtle', style: 'font-size:11px; margin-top:2px', text: meta }),
        el('div', {},
          el('button', { class: 'ghost tiny', text: '✔ use', onclick: async e => {
            e.target.disabled = true;
            try { await use(); } catch (err) { toast(err.message, 'err'); }
            e.target.disabled = false;
          } }),
          el('button', { class: 'ghost tiny', text: '✕', title: 'Remove from the pool', onclick: async () => {
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
      + 'Click to inspect full-size; ✔ swaps it in as the workspace art — deploying stays explicit.' }),
    grid,
    el('div', { class: 'modal-actions' },
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
  // step-1 ANCHOR: the concept image the whole tree grows from. ALWAYS offer the real
  // choices — current art, the card's base piece art (resolved here, whether or not a
  // recipe set it), the recipe's own reference, an upload — defaulting to the recipe's
  // pick when there is one, "none" otherwise.
  const basePiece = (() => {
    if (type !== 'card' || !state.draft) return null;
    const pieces = [...(state.draft.chess_pieces || [])].sort();
    if (!pieces.length) return null;
    const key = '|' + pieces.join('_');
    const hit = (state.game.card || []).find(g => g.id !== id && setCompKey(g) === key && g.art);
    return hit ? { path: hit.art, name: hit.name || hit.id } : null;
  })();
  const anchorCfg = { source: (a0.refSource && a0.refSource !== 'none') ? a0.refSource : 'none' };
  const buildAnchorOpts = () => [
    { value: 'none', label: 'None — from scratch' },
    (state.gameArt || state.gameHasArt) ? { value: 'current', label: 'Current art' } : null,
    (basePiece && (!a0.refGameArt || a0.refGameArt !== basePiece.path))
      ? { value: 'base', label: `Base piece art: ${basePiece.name}` } : null,
    a0.refGameArt ? { value: 'game', label: `${a0.refGameArt === (basePiece && basePiece.path) ? 'Base piece art' : 'Recipe reference'}: ${a0.refGameName || a0.refGameArt}` } : null,
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
        const pick = async () => {
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
          toast(`Candidate #${nd.n} is now this item's workspace art`
            + (state.types[type].rembg ? ' (background removed)' : '') + ' — deploy when ready.', 'ok');
          renderSidePanels();
        };
        rowEl.append(el('div', { style: 'width:224px' },
          el('img', { src, loading: 'lazy',
            title: caption + ' — click to inspect full-size',
            style: 'width:224px; height:auto; border-radius:6px; cursor:zoom-in',
            onclick: () => openLightbox(src, caption, pick) }),
          el('div', {},
            el('span', { class: 'subtle', style: 'font-size:11px; margin-right:6px', text: caption }),
            el('button', { class: 'ghost tiny', text: '✔ use', onclick: async e => {
              e.target.disabled = true;
              try { await pick(); } catch (err) { toast(err.message, 'err'); }
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
      if (j.status === 'running') {
        status.className = 'art-status';
        status.textContent = `Running — step ${j.stepNow}/${j.stepCount}, image ${j.done + 1} of ${j.total} (${j.elapsed}s)…`;
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
        : anchorCfg.source === 'base' ? { source: 'game', path: basePiece.path }
        : {
          source: anchorCfg.source,
          path: anchorCfg.source === 'game' ? a.refGameArt
            : anchorCfg.source === 'upload' ? a.refUpload : undefined,
        };
      const out = await api('/api/art/flow', { type, id, prompt: currentPrompt,
        negative: a.negative || '', steps: cfg.map(st => Object.assign({}, st)), anchor });
      gallery.replaceChildren();
      attach(out.jobId);
    } catch (e) { toast(e.message, 'err'); }
  } });

  const modal = el('div', { class: 'modal', style: 'width:820px; max-height:86vh; overflow-y:auto' },
    el('h2', {}, '⛓ Multi-step generation — ', el('span', { class: 'subtle', text: id })),
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
          const policyMap = { none: 'none', current: 'current', base: 'base', game: 'recipe', upload: 'none' };
          const policy = policyMap[anchorCfg.source] || 'recipe';
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

// ── boot ─────────────────────────────────────────────────────────────────────
$('new-item-btn').addEventListener('click', newItem);
$('gen-set-btn').addEventListener('click', openSetGenerator);
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
