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
  renderTabs(); renderItemList();
  if (!keepEditor) renderEditor();
  else refreshInstallBar();
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
    ));
    if (!expanded) continue;
    for (const g of entries) {
      list.append(el('div', {
        class: 'item-row tree-leaf' + (state.mode === 'game' && state.currentId === g.id ? ' active' : ''),
        onclick: () => {
          if (!confirmDiscard()) return;
          openGameItem(g.id);
        },
      },
        g.art ? el('img', { class: 'thumb', loading: 'lazy', src: '/gameart/' + g.art }) : null,
        el('div', { class: 'item-name' }, el('div', { text: g.name }), el('div', { class: 'item-id', text: g.id })),
        g.edited ? el('span', { class: 'pill installed', text: 'edited' }) : null,
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
  return { vocab: state.vocab, workspace: ws, isNew: state.isNew };
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
  return { width: t.artW, height: t.artH, rembg: t.rembg, steps: 20, guidance: 4.0, seed: -1 };
}

function renderArtPanel() {
  const panel = $('art-panel');
  const ed = EDITORS[state.currentType];
  const t = state.types[state.currentType];
  panel.replaceChildren(el('h3', { text: 'Art (ComfyUI)' }));

  if (!state.draft._art) state.draft._art = Object.assign(artDefaults(), { prompt: '' });
  const a = state.draft._art;
  if (!a.model || !state.artModels[a.model]) {
    // Krea 2 is the house default — adopt its step/guidance profile along with the pick
    a.model = state.artModels.krea2 ? 'krea2' : 'flux2';
    const m0 = state.artModels[a.model];
    if (m0) { a.steps = m0.steps; a.guidance = m0.guidance; }
  }
  const mdl = state.artModels[a.model];

  const noChange = () => { state.dirty = true; $('dirty-flag').hidden = false; };
  // empty prompt = auto-derive from the item's current name/description at generate time
  const promptArea = el('textarea', {
    value: a.prompt || '', rows: 3, placeholder: 'auto: ' + ed.promptFor(state.draft),
    oninput: e => { a.prompt = e.target.value; noChange(); },
  });

  // ── shared STYLE prompt: one global fragment appended to every generation, with presets ──
  if (!state.settings.stylePresets) state.settings.stylePresets = {};
  const styleArea = el('textarea', {
    value: state.settings.artStyle || '', rows: 2,
    placeholder: 'e.g. cartoon art style, 2d illustration — appended to every prompt',
    oninput: e => { state.settings.artStyle = e.target.value; saveStyleSoon(); },
  });
  const presetSel = el('select', {
    onchange: e => {
      if (!e.target.value) return;
      state.settings.artStyle = state.settings.stylePresets[e.target.value] || '';
      styleArea.value = state.settings.artStyle;
      saveStyleSoon();
    },
  });
  const rebuildPresets = () => {
    presetSel.replaceChildren(el('option', { value: '', text: 'presets…' }));
    for (const name of Object.keys(state.settings.stylePresets).sort())
      presetSel.append(el('option', { value: name, text: name }));
  };
  rebuildPresets();
  const styleRow = el('div', { class: 'frow' },
    el('div', { class: 'fld wide' },
      el('span', { class: 'lab' }, 'Style (shared across ALL generations) ',
        el('button', { class: 'ghost tiny', text: '＋ save preset', title: 'Save the current style text as a named preset',
          onclick: async () => {
            const name = (window.prompt('Preset name:', '') || '').trim();
            if (!name) return;
            state.settings.stylePresets[name] = styleArea.value;
            rebuildPresets(); presetSel.value = name;
            await saveStyleNow();
            toast(`Style preset "${name}" saved.`, 'ok');
          } }),
        el('button', { class: 'ghost tiny', text: '− delete', title: 'Delete the selected preset',
          onclick: async () => {
            if (!presetSel.value) return;
            delete state.settings.stylePresets[presetSel.value];
            rebuildPresets();
            await saveStyleNow();
          } }),
        presetSel),
      styleArea),
  );

  // ── reference image: the item's current art, or an external image the user uploads ──
  const artAvail = !!state.gameArt || state.gameHasArt;
  const refSrcLabel = state.gameArt ? 'the in-game art' : 'the latest generated image';
  if (a.useRef && !a.refSource) a.refSource = 'current';   // drafts from the checkbox era
  if (!a.refSource || !mdl.supportsRef) a.refSource = mdl.supportsRef ? a.refSource || 'none' : 'none';
  if (a.refSource === 'current' && !artAvail) a.refSource = 'none';   // offering it would only error
  const refActive = a.refSource !== 'none';
  const refRow = el('div', { class: 'frow' },
    fld('Reference image', mdl.supportsRef
      ? selectInput(a, 'refSource', [
          { value: 'none', label: 'None' },
          artAvail ? { value: 'current', label: `Current art (${refSrcLabel})` } : null,
          { value: 'upload', label: 'Uploaded image…' },
        ].filter(Boolean), () => { noChange(); renderArtPanel(); })
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
          noChange(); renderArtPanel();
        } catch (err) { toast('Reference upload failed: ' + err.message, 'err'); }
      } })) : null,
  );

  if (mdl.refModes && refActive && !mdl.refModes.some(rm => rm.value === a.refMode)) a.refMode = mdl.refModes[0].value;
  if (mdl.refModes && a.denoise == null) a.denoise = 0.6;
  const refModeRow = (mdl.refModes && refActive) ? el('div', { class: 'frow' },
    fld('Reference mode', selectInput(a, 'refMode', mdl.refModes, () => { noChange(); renderArtPanel(); })),
    a.refMode === 'img2img'
      ? fld('Denoise', numInput(a, 'denoise', noChange, { float: true, step: 0.05, min: 0.05, max: 1 }),
            'Lower = closer to the reference; higher = more freedom to restyle')
      : null,
  ) : null;

  // ── model picker: each entry is a full architecture with its own defaults ──
  const modelRow = el('div', { class: 'frow' },
    fld('Model', selectInput(a, 'model', Object.entries(state.artModels)
      .map(([k, v]) => ({ value: k, label: v.label })), () => {
      // switching models adopts that model's step/guidance profile
      const nm = state.artModels[a.model];
      a.steps = nm.steps;
      a.guidance = nm.guidance;
      if (!nm.supportsRef) { a.useRef = false; a.refSource = 'none'; }
      if (!nm.supportsTurbo) a.turbo = false;
      noChange(); renderArtPanel();
    })),
  );

  panel.append(
    modelRow,
    el('div', { class: 'frow' },
      el('div', { class: 'fld wide' },
        el('span', { class: 'lab' }, 'Prompt ',
          el('button', { class: 'ghost tiny', text: '↻ auto', title: 'Re-derive the template prompt from the item’s name/composition',
            onclick: () => { a.prompt = ed.promptFor(state.draft); promptArea.value = a.prompt; noChange(); } }),
          el('button', { class: 'ghost tiny', text: '✨ llm', title: 'Ask the local LLM (Ollama, see Settings) to write a rich prompt from the item’s full data — press again to re-roll',
            onclick: async e => {
              const btn = e.target;
              btn.disabled = true; btn.textContent = '✨ thinking…';
              try {
                const out = await api('/api/art/prompt', {
                  type: state.currentType,
                  name: state.draft.display_name || state.draft.id || 'unnamed',
                  summary: ed.summarize(state.draft),
                  example: ed.promptFor(state.draft),
                });
                a.prompt = out.prompt; promptArea.value = out.prompt; noChange();
              } catch (err) { toast('LLM prompt failed: ' + err.message, 'err'); }
              btn.disabled = false; btn.textContent = '✨ llm';
            } })),
        promptArea),
    ),
    mdl.supportsNegative ? el('div', { class: 'frow' },
      el('div', { class: 'fld wide' },
        el('span', { class: 'lab', text: 'Negative prompt (empty = the usual booru quality negatives)' }),
        el('textarea', { value: a.negative || '', rows: 2,
          placeholder: 'worst quality, low quality, watermark, …',
          oninput: e => { a.negative = e.target.value; noChange(); } })),
    ) : document.createTextNode(''),   // native append() stringifies null
    styleRow,
    refRow,
    refModeRow || document.createTextNode(''),
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
            type: 'checkbox', checked: !!a.turbo, disabled: !mdl.supportsTurbo,
            onchange: e => {
              a.turbo = e.target.checked;
              // swap the steps default along with the mode (only if the user hasn't customized)
              const turboSteps = state.settings.turboSteps || 8;
              if (a.turbo && a.steps === 20) a.steps = turboSteps;
              else if (!a.turbo && a.steps === turboSteps) a.steps = 20;
              noChange(); renderArtPanel();
            },
          }),
          mdl.supportsTurbo ? `⚡ Turbo LoRA (~${state.settings.turboSteps || 8} steps, much faster)`
            : `⚡ Turbo LoRA — Flux 2 only`)),
    ),
    el('div', { class: 'hint', text: ed.artNote }),
  );

  const status = el('div', { class: 'art-status' });
  const genBtn = el('button', { class: 'primary', text: '🎨 Generate', style: 'margin-top:10px', onclick: () => startArt(status, genBtn) });
  if (state.isNew || !state.currentId) { genBtn.disabled = true; status.textContent = 'Save the item first (art is filed under its id).'; }
  if (state.artJob && state.artJob.itemId === state.currentId) genBtn.disabled = true;
  panel.append(genBtn, status);
  if (state.artJob && state.artJob.itemId === state.currentId) {
    status.textContent = `Generating… ${state.artJob.elapsed || 0}s`;
    panel.append(el('div', { class: 'progressbar' }, el('div')));
  }

  // Art the game currently shows for this item (installed art) — always presented.
  const installedArt = state.gameArt;
  if (installedArt) {
    panel.append(
      el('div', { class: 'lab subtle', style: 'margin-top:10px', text: 'In-game art — ' + installedArt }),
      el('img', { class: 'art-preview', loading: 'lazy', src: '/gameart/' + installedArt + '?ts=' + Date.now() }),
    );
  }

  const hasArt = state.gameHasArt;
  if (hasArt && installedArt) {
    panel.append(el('div', { class: 'lab subtle', style: 'margin-top:10px', text: 'Generated (workspace)' }));
  }
  // Flip works off whichever image is current (workspace art preferred, else in-game art)
  // and always lands in the WORKSPACE — deploying the flip stays an explicit act.
  const flipBtn = (hasArt || installedArt) ? el('button', { class: 'ghost small', text: '⇋ Flip horizontally', style: 'margin-right:6px',
    title: 'Mirror the image left-right (result goes to the workspace; press "Use in game" to deploy it)',
    onclick: () => flipArtHorizontal(hasArt ? null : installedArt) }) : null;
  if (hasArt) {
    panel.append(el('img', { class: 'art-preview', src: `/art/${state.currentType}/${state.currentId}.png?ts=${Date.now()}` }));
    // Generation never touches the game's assets — this button is the explicit deploy act.
    const canDeploy = state.mode === 'game' && !state.isNew && !!t.artDir;
    if (canDeploy)
      panel.append(el('div', { class: 'hint', style: 'margin-top:6px', text: 'Kept in the tool workspace until you press "Use in game" (any replaced art is backed up).' }));
    panel.append(el('div', { style: 'margin-top:6px' },
      canDeploy ? el('button', { class: 'primary small', text: '⬆ Use in game', style: 'margin-right:6px', onclick: async () => {
        try {
          const out = await api('/api/art/deploy', { type: state.currentType, id: state.currentId });
          toast(`Deployed to ${out.art} (give the Godot editor focus once to import it).`, 'ok');
          state.gameArt = out.art;
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
    panel.append(el('div', { style: 'margin-top:6px' }, flipBtn));
  }
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

async function startArt(statusEl, btn) {
  const a = state.draft._art;
  btn.disabled = true;
  statusEl.className = 'art-status';
  statusEl.textContent = 'Queueing…';
  await saveStyleNow();
  const base = a.prompt || EDITORS[state.currentType].promptFor(state.draft);
  const style = (state.settings.artStyle || '').trim();
  try {
    const { jobId } = await api('/api/art/generate', {
      type: state.currentType, id: state.currentId,
      prompt: style ? base + ', ' + style : base,
      negative: a.negative || '',
      width: a.width, height: a.height,
      steps: a.steps, guidance: a.guidance, seed: a.seed, rembg: a.rembg,
      useRef: !!a.refSource && a.refSource !== 'none',
      refUpload: a.refSource === 'upload' ? a.refUpload : undefined,
      refMode: a.refMode, denoise: a.denoise, turbo: !!a.turbo,
      model: a.model || 'flux2',
    });
    state.artJob = { jobId, itemId: state.currentId, type: state.currentType, elapsed: 0 };
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
        const s = document.querySelector('#art-panel .art-status');
        if (s) s.textContent = `Generating… ${j.elapsed}s`;
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
    if (sorted.length) card.chess_pieces = sorted;
    if (cfg.description) card.description = cfg.description;
    if (cfg.effects.length) card.effects = cfg.effects.map(cleanEffectForDeploy);
    return card;
  });
}

function openSetGenerator() {
  const cfg = { a: 'water', b: '', singles: true, pairs: true, spell: false,
    description: '', effects: [], install: true };
  const preview = el('div', { class: 'subtle mono', style: 'margin-top:8px; line-height:1.6' });
  const refresh = () => {
    const cards = generateSetCards(cfg);
    const existing = new Set([...state.vocab.cards.map(c => c.id), ...(state.items.card || []).map(i => i.id)]);
    const fresh = cards.filter(c => !existing.has(c.id));
    preview.textContent = cards.length
      ? `${fresh.length} new cards` + (cards.length - fresh.length ? ` (${cards.length - fresh.length} skipped — ids already exist)` : '')
        + ': ' + fresh.map(c => c.id).join(', ')
      : 'pick at least one element';
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
        const existing = new Set(state.vocab.cards.map(c => c.id));
        const cards = generateSetCards(cfg).filter(c => !existing.has(c.id));
        if (!cards.length) { toast('Nothing to generate — every id already exists.', 'err'); return; }
        // the whole family lives in ONE normally-named game file, each entry an ordinary card
        const setFile = [cfg.a, cfg.b].filter(Boolean).sort().join('_') + '_units.json';
        let made = 0;
        for (const card of cards) {
          try {
            await api('/api/game/save', { type: 'card', file: setFile, data: card });
            made++;
          } catch (e) { toast(`${card.id}: ${e.message}`, 'err'); }
        }
        $('modal-root').replaceChildren();
        toast(`${made} cards saved into data/cards/${setFile} — in the game (restart it to see them).`, 'ok');
        await refreshState();
      } }),
    ));
  $('modal-root').replaceChildren(modal);
  refresh();
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
    ollamaUrl: state.settings.ollamaUrl || 'http://127.0.0.1:11434',
    llmModel: state.settings.llmModel || 'gemma4:31b',
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
    el('div', { class: 'frow', style: 'margin-top:10px' },
      fld('Ollama URL', textInput(s, 'ollamaUrl', () => {}, 'http://127.0.0.1:11434'), 'local LLM server for ✨ art prompts'),
      fld('LLM model', textInput(s, 'llmModel', () => {}, 'gemma4:31b'), 'an Ollama model name'),
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
$('copy-json').addEventListener('click', () => {
  navigator.clipboard.writeText($('json-preview').textContent);
  toast('JSON copied.');
});
window.addEventListener('beforeunload', e => { if (state.dirty) e.preventDefault(); });

refreshState().then(checkComfy).catch(e => toast('Failed to load: ' + e.message, 'err'));
setInterval(checkComfy, 30000);
