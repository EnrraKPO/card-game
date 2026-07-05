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
  const list = $('item-list');
  list.replaceChildren();
  const items = (state.items[state.currentType] || []).slice()
    .sort((a, b) => a.id.localeCompare(b.id));
  if (!items.length) list.append(el('div', { class: 'subtle', style: 'padding:10px', text: 'Nothing authored yet.' }));
  for (const it of items) {
    const name = (it.data && it.data.display_name) || it.id;
    const thumbSrc = it.hasArt ? `/art/${state.currentType}/${it.id}.png`
      : it.gameArt ? '/gameart/' + it.gameArt : null;
    list.append(el('div', {
      class: 'item-row' + (state.mode === 'ws' && state.currentId === it.id ? ' active' : ''),
      onclick: () => { if (!confirmDiscard()) return; openItem(it.id); },
    },
      thumbSrc ? el('img', { class: 'thumb', loading: 'lazy', src: thumbSrc }) : null,
      el('div', { class: 'item-name' }, el('div', { text: name }), el('div', { class: 'item-id', text: it.id })),
      it.hasArt ? el('span', { class: 'pill art', text: 'art' }) : null,
      it.installed ? el('span', { class: 'pill installed', text: 'installed' }) : el('span', { class: 'pill', text: 'draft' }),
    ));
  }

  // ── existing game content (edit in place): a tree, grouped by source json file ──
  const gameItems = (state.game[state.currentType] || []).slice()
    .sort((a, b) => a.id.localeCompare(b.id));
  if (!gameItems.length) return;
  list.append(el('div', { style: 'display:flex;align-items:center;gap:8px;padding:14px 4px 6px' },
    el('span', { style: 'font-weight:600', text: 'Game content' }),
    el('span', { class: 'subtle', text: gameItems.length + '' })));
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
        onclick: () => { if (!confirmDiscard()) return; openGameItem(g.id); },
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
function openItem(id) {
  const it = (state.items[state.currentType] || []).find(x => x.id === id);
  if (!it) return;
  state.mode = 'ws';
  state.currentId = id;
  state.isNew = false;
  state.draft = JSON.parse(JSON.stringify(it.data));
  state.dirty = false;
  renderItemList(); renderEditor();
}

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
  state.dirty = false;
  renderItemList(); renderEditor();
}

function newItem() {
  if (!confirmDiscard()) return;
  state.mode = 'ws';
  state.currentId = null;
  state.isNew = true;
  state.draft = EDITORS[state.currentType].newItem();
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

  const prefix = state.mode === 'game' ? 'Game ' : (state.isNew ? 'New ' : '');
  $('item-title').textContent = prefix + ed.label +
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

// ── install bar ──────────────────────────────────────────────────────────────
function currentItemMeta() {
  return (state.items[state.currentType] || []).find(x => x.id === state.currentId);
}

function refreshInstallBar() {
  const t = state.types[state.currentType];
  const info = $('install-info');
  const save = $('save-btn'), upd = $('update-btn'), inst = $('install-btn'), del = $('delete-btn');

  if (state.mode === 'game') {
    save.hidden = true;
    inst.hidden = true;
    upd.hidden = false;
    upd.textContent = 'Apply to game';
    upd.className = 'primary';
    del.hidden = !state.gameEdited;
    del.textContent = 'Restore original';
    info.innerHTML = 'Editing GAME content in place: <b>' + t.dataDir + '/' + state.gameFile + '</b>' +
      (state.gameEdited ? ' — original snapshot kept, restorable' : '') +
      (state.dirty ? ' — <span style="color:var(--accent)">changes not applied yet</span>' : '');
    return;
  }

  save.hidden = false;
  inst.hidden = false;
  del.hidden = false;
  del.textContent = 'Delete';
  const it = currentItemMeta();
  const installed = it && it.installed;
  inst.textContent = installed ? 'Uninstall from game' : 'Install into game';
  inst.className = installed ? 'danger' : 'primary';
  inst.disabled = state.isNew;
  upd.hidden = !installed;
  upd.textContent = 'Push update';
  upd.className = 'primary';
  if (state.isNew) info.textContent = 'Save first — installing deploys the JSON into ' + (t ? t.dataDir : '') + '.';
  else if (installed) info.innerHTML = 'Deployed as <b>' + t.dataDir + '/tool_' + state.currentType + '_' + state.currentId + '.json</b>' +
    (state.dirty ? ' — <span style="color:var(--accent)">save + reinstall to push your changes</span>' : '');
  else info.textContent = 'Draft only — press Install to deploy into ' + t.dataDir + '.';
}

async function saveDraft() {
  if (state.mode === 'game') return applyGame();
  const ed = EDITORS[state.currentType];
  let data;
  try { data = ed.serialize(state.draft); } catch (e) { toast('Cannot serialize: ' + e.message, 'err'); return false; }
  if (state.draft._art) data._art = state.draft._art;   // persist art settings (stripped on deploy)
  if (!/^[a-z0-9_]+$/.test(data.id || '')) {
    showValidation('id must be lowercase letters, digits and underscores'); return false;
  }
  // duplicate-id guard on create
  if (state.isNew && (state.items[state.currentType] || []).some(x => x.id === data.id)) {
    showValidation(`A ${state.currentType} with id "${data.id}" already exists in the workspace.`); return false;
  }
  try {
    await api('/api/item/save', { type: state.currentType, data });
  } catch (e) { toast('Save failed: ' + e.message, 'err'); return false; }
  state.currentId = data.id;
  state.isNew = false;
  state.dirty = false;
  await refreshState(true);
  renderItemList();
  renderSidePanels();   // art panel unlocks once the item exists under its id
  $('dirty-flag').hidden = true;
  $('item-title').textContent = EDITORS[state.currentType].label +
    (state.draft.display_name ? ' — ' + state.draft.display_name : ' — ' + state.draft.id);
  // validate quietly so problems surface early
  const v = await api('/api/validate', { type: state.currentType, data });
  if (!v.ok) showValidation('Saved, but not installable yet: ' + v.error);
  else { showValidation('Saved. Valid and ready to install.', true); }
  return true;
}

function showValidation(msg, ok) {
  const box = $('validation-msg');
  box.hidden = false;
  box.className = ok ? 'ok' : '';
  box.textContent = msg;
}

async function installOrUninstall() {
  const it = currentItemMeta();
  if (!it) return;
  try {
    if (it.installed) {
      const out = await api('/api/item/uninstall', { type: state.currentType, id: state.currentId });
      toast('Uninstalled — removed ' + (out.removed.length ? out.removed.join(', ') : 'manifest entry'), 'ok');
    } else {
      if (state.dirty && !await saveDraft()) return;
      const out = await api('/api/item/install', { type: state.currentType, id: state.currentId });
      toast('Installed → ' + out.files.join(', '), 'ok');
    }
  } catch (e) {
    toast(e.message, 'err');
  }
  await refreshState(true);
  renderItemList();
}

// Re-deploy the (saved) draft over the already-installed files.
async function pushUpdate() {
  if (state.mode === 'game') return applyGame();
  if (state.dirty && !await saveDraft()) return;
  try {
    const out = await api('/api/item/install', { type: state.currentType, id: state.currentId });
    toast('Updated → ' + out.files.join(', '), 'ok');
  } catch (e) { toast(e.message, 'err'); }
  await refreshState(true);
  renderItemList();
}

// Write the edited game entry back into its own file (snapshotting the original first).
async function applyGame() {
  const ed = EDITORS[state.currentType];
  let data;
  try { data = ed.serialize(state.draft); } catch (e) { toast('Cannot serialize: ' + e.message, 'err'); return; }
  let applyArt = false;
  if (state.gameHasArt && state.types[state.currentType].artDir) {
    applyArt = confirm('Also replace this item’s game art with the generated image?\n(The current art is backed up and restored with "Restore original".)');
  }
  try {
    const out = await api('/api/game/apply', { type: state.currentType, id: state.currentId, data, applyArt });
    toast('Applied to ' + out.file + (out.art && out.art.length ? ' (+ art)' : ''), 'ok');
    state.dirty = false;
    state.gameEdited = true;
  } catch (e) { toast(e.message, 'err'); return; }
  await refreshState(true);
  renderItemList();
}

async function restoreGame() {
  if (!confirm(`Restore "${state.currentId}" to its original state (undo all tool edits)?`)) return;
  try {
    const out = await api('/api/game/restore', { type: state.currentType, id: state.currentId });
    toast('Restored original in ' + out.file, 'ok');
  } catch (e) { toast(e.message, 'err'); return; }
  await refreshState(true);
  await openGameItem(state.currentId);
}

async function deleteItem() {
  if (state.mode === 'game') return restoreGame();
  if (state.isNew) { state.draft = null; renderEditor(); return; }
  if (!confirm(`Delete ${state.currentType} "${state.currentId}" from the workspace?\n(It will be uninstalled from the game first if installed.)`)) return;
  try {
    await api('/api/item/delete', { type: state.currentType, id: state.currentId });
    toast('Deleted.', 'ok');
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
  panel.replaceChildren(el('h3', { text: 'Art (ComfyUI · Flux 2 dev)' }));

  if (!state.draft._art) state.draft._art = Object.assign(artDefaults(), { prompt: '' });
  const a = state.draft._art;

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

  // ── use the current art as an image reference ──
  const refAvail = state.mode === 'game' ? (!!state.gameArt || state.gameHasArt)
    : !!(currentItemMeta() && (currentItemMeta().gameArt || currentItemMeta().hasArt));
  const refSrcLabel = (state.mode === 'game' ? state.gameArt : (currentItemMeta() && currentItemMeta().gameArt))
    ? 'the in-game art' : 'the generated workspace image';
  const refCheck = el('label', { class: 'check' },
    el('input', {
      type: 'checkbox', checked: !!a.useRef, disabled: !refAvail,
      onchange: e => { a.useRef = e.target.checked; noChange(); },
    }),
    refAvail ? `Use current art as input (${refSrcLabel})` : 'Use current art as input — no current art');

  panel.append(
    el('div', { class: 'frow' },
      el('div', { class: 'fld wide' },
        el('span', { class: 'lab' }, 'Prompt ',
          el('button', { class: 'ghost tiny', text: '↻ auto', title: 'Re-derive the prompt from the item’s name/description',
            onclick: () => { a.prompt = ed.promptFor(state.draft); promptArea.value = a.prompt; noChange(); } })),
        promptArea),
    ),
    styleRow,
    el('div', { class: 'frow' }, el('div', { class: 'fld' }, refCheck)),
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
            type: 'checkbox', checked: !!a.turbo,
            onchange: e => {
              a.turbo = e.target.checked;
              // swap the steps default along with the mode (only if the user hasn't customized)
              const turboSteps = state.settings.turboSteps || 8;
              if (a.turbo && a.steps === 20) a.steps = turboSteps;
              else if (!a.turbo && a.steps === turboSteps) a.steps = 20;
              noChange(); renderArtPanel();
            },
          }),
          `⚡ Turbo LoRA (~${state.settings.turboSteps || 8} steps, much faster)`)),
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
  const installedArt = state.mode === 'game' ? state.gameArt
    : (currentItemMeta() && currentItemMeta().gameArt);
  if (installedArt) {
    panel.append(
      el('div', { class: 'lab subtle', style: 'margin-top:10px', text: 'In-game art — ' + installedArt }),
      el('img', { class: 'art-preview', loading: 'lazy', src: '/gameart/' + installedArt + '?ts=' + Date.now() }),
    );
  }

  const it = currentItemMeta();
  const hasArt = state.mode === 'game' ? state.gameHasArt : (it && it.hasArt);
  if (hasArt && installedArt) {
    panel.append(el('div', { class: 'lab subtle', style: 'margin-top:10px', text: 'Generated (workspace)' }));
  }
  if (hasArt) {
    panel.append(el('img', { class: 'art-preview', src: `/art/${state.currentType}/${state.currentId}.png?ts=${Date.now()}` }));
    if (state.mode === 'game')
      panel.append(el('div', { class: 'hint', style: 'margin-top:6px', text: 'This generated image replaces the game art when you Apply (you will be asked; the original is backed up).' }));
    panel.append(el('div', { style: 'margin-top:6px' },
      el('button', { class: 'ghost small', text: 'Discard art', onclick: async () => {
        await api('/api/art/delete', { type: state.currentType, id: state.currentId });
        state.gameHasArt = false;
        await refreshState(true); renderSidePanels(); renderItemList();
      } })));
  }
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
      width: a.width, height: a.height,
      steps: a.steps, guidance: a.guidance, seed: a.seed, rembg: a.rembg,
      useRef: !!a.useRef, turbo: !!a.turbo,
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
        if (s) s.textContent = `Generating… ${j.elapsed}s (Flux 2 typically needs 60–100s)`;
      }
      setTimeout(pollArt, 2000);
      return;
    }
    const finished = state.artJob;
    state.artJob = null;
    if (j.status === 'done') {
      toast(`Art ready for ${finished.itemId}.`, 'ok');
      if (state.mode === 'game' && state.currentId === finished.itemId) state.gameHasArt = true;
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
$('save-btn').addEventListener('click', saveDraft);
$('install-btn').addEventListener('click', installOrUninstall);
$('update-btn').addEventListener('click', pushUpdate);
$('delete-btn').addEventListener('click', deleteItem);
$('settings-btn').addEventListener('click', openSettings);
$('copy-json').addEventListener('click', () => {
  navigator.clipboard.writeText($('json-preview').textContent);
  toast('JSON copied.');
});
window.addEventListener('beforeunload', e => { if (state.dirty) e.preventDefault(); });

refreshState().then(checkComfy).catch(e => toast('Failed to load: ' + e.message, 'err'));
setInterval(checkComfy, 30000);
