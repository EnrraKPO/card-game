/* ui_test.js — drives the real UI in Chrome through every authoring flow, against a
 * SANDBOX game root AND an isolated tool workspace (never touches Tool/workspace).
 * Screenshots land in test/shots/. Run: node test/ui_test.js  */
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const puppeteer = require('puppeteer-core');

const TOOL = path.resolve(__dirname, '..');
const SHOTS = path.join(__dirname, 'shots');
const SANDBOX = fs.mkdtempSync(path.join(os.tmpdir(), 'cardgame-ui-sandbox-'));
const WS_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'cardgame-ui-toolws-'));
const PORT = 8478;
const BASE = `http://127.0.0.1:${PORT}`;
const CHROME = ['C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(fs.existsSync);

for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map', 'assets/cards', 'assets/relics', 'assets/abilities'])
  fs.mkdirSync(path.join(SANDBOX, d), { recursive: true });
fs.writeFileSync(path.join(SANDBOX, 'data/cards/base.json'), JSON.stringify([
  { id: 'pawn', display_name: 'Pawn', cost: 1, attack: 1, health: 2, speed: 3, chess_pieces: ['pawn'] },
  { id: 'goblin_cutter', display_name: 'Goblin Cutter', cost: 1, attack: 2, health: 1, speed: 4, enemy_only: true },
  { id: 'goblin_warlord', display_name: 'Goblin Warlord', cost: 0, attack: 3, health: 20, speed: 2, is_king: true, enemy_only: true },
]));
fs.writeFileSync(path.join(SANDBOX, 'data/statuses/poison.json'), JSON.stringify({ id: 'poison', display_name: 'Poison' }));
fs.writeFileSync(path.join(SANDBOX, 'data/abilities/castling.json'), JSON.stringify({ id: 'castling', display_name: 'Castling' }));
// give the sandbox pawn installed game art (a real 1×1 png so <img> decodes)
fs.writeFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'),
  Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64'));
fs.mkdirSync(SHOTS, { recursive: true });

let failures = 0;
function check(name, cond, extra) {
  if (cond) console.log('  ok  ' + name);
  else { failures++; console.log('FAIL  ' + name + (extra ? ' — ' + extra : '')); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function main() {
  const server = spawn(process.execPath, [path.join(TOOL, 'server.js'), String(PORT)], {
    env: Object.assign({}, process.env, { CARDGAME_ROOT: SANDBOX, CARDGAME_WORKSPACE: WS_DIR }), stdio: 'ignore',
  });
  await sleep(700);
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new',
    args: ['--window-size=1600,1000'] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1600, height: 1000 });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });

  // dialogs (confirm on delete etc.) — accept
  page.on('dialog', d => d.accept());

  const shot = n => page.screenshot({ path: path.join(SHOTS, n + '.png') });

  async function clickTab(label) {
    await page.evaluate(l => {
      [...document.querySelectorAll('#type-tabs button')].find(b => b.textContent.includes(l)).click();
    }, label);
    await sleep(150);
  }
  async function clickNew() { await page.click('#new-item-btn'); await sleep(150); }
  async function setFld(labelText, value) {
    const ok = await page.evaluate((lab, val) => {
      const fld = [...document.querySelectorAll('#form-col .fld')]
        .find(f => { const s = f.querySelector('span.lab'); return s && s.textContent === lab; });
      if (!fld) return false;
      const inp = fld.querySelector('input, textarea, select');
      if (!inp) return false;
      if (inp.tagName === 'SELECT') { inp.value = val; inp.dispatchEvent(new Event('change', { bubbles: true })); }
      else {
        inp.value = val;
        inp.dispatchEvent(new Event('input', { bubbles: true }));
        inp.dispatchEvent(new Event('change', { bubbles: true }));
      }
      return true;
    }, labelText, String(value));
    if (!ok) throw new Error('field not found: ' + labelText);
    await sleep(60);
  }
  async function clickChip(text) {
    const ok = await page.evaluate(t => {
      const chip = [...document.querySelectorAll('#form-col .chip')].find(c => c.textContent === t && !c.classList.contains('on'));
      if (!chip) return false;
      chip.click(); return true;
    }, text);
    if (!ok) throw new Error('chip not found: ' + text);
    await sleep(60);
  }
  async function clickBtn(text, scope) {
    const ok = await page.evaluate((t, sc) => {
      const root = sc ? document.querySelector(sc) : document;
      const b = [...root.querySelectorAll('button')].find(x => x.textContent.trim() === t);
      if (!b || b.disabled) return false;
      b.click(); return true;
    }, text, scope || null);
    if (!ok) throw new Error('button not found/disabled: ' + text);
    await sleep(200);
  }
  async function save() { await page.click('#save-btn'); await sleep(400); }
  async function install() {
    await page.evaluate(() => document.getElementById('install-btn').click());
    await sleep(500);
  }
  const jsonPreview = () => page.evaluate(() => document.getElementById('json-preview').textContent);
  const summary = () => page.evaluate(() => document.getElementById('summary-body').textContent);

  try {
    await page.goto(BASE, { waitUntil: 'networkidle0' });
    await sleep(400);
    await shot('00_landing');
    check('app loads', await page.$('#type-tabs button') !== null);

    // ═══ CARD flow: composition card with a poison-on-hit effect + condition ═══
    await clickTab('Cards'); await clickNew();
    await setFld('ID', 'ui_ember_stinger');
    await setFld('Name', 'Ember Stinger');
    await setFld('Mana cost', 2); await setFld('Attack', 3); await setFld('Health', 3); await setFld('Speed', 5);
    await clickChip('Fire'); await clickChip('Pawn');
    await clickBtn('+ add effect');
    // effect defaults to triggered on_play/self/attack+1 — retarget it
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const selects = card.querySelectorAll('select');
      // [kind, trigger, subject, policy]
      selects[1].value = 'on_attack'; selects[1].dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(100);
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const sel = [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === 'Affects').querySelector('select');
      sel.value = 'attack_target'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(100);
    // clear stat change, apply poison instead
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const sel = [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === 'Change stat').querySelector('select');
      sel.value = ''; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(100);
    await clickBtn('+ also apply a status');
    await shot('01_card_editor');
    let js = await jsonPreview();
    check('card json has poison-on-attack', js.includes('"on_attack"') && js.includes('"poison"') && js.includes('"attack_target"'), js);
    check('card summary in plain words', (await summary()).includes('Each time it attacks'));
    await save();
    check('card saved + valid', (await page.evaluate(() => document.getElementById('validation-msg').textContent)).includes('ready to install'));
    await install();
    const cardFile = path.join(SANDBOX, 'data/cards/tool_card_ui_ember_stinger.json');
    check('card installed to sandbox', fs.existsSync(cardFile));
    const deployed = JSON.parse(fs.readFileSync(cardFile, 'utf8'));
    check('deployed card effect intact', deployed.effects[0].status.id === 'poison' && deployed.effects[0].targeting_policy === 'attack_target');
    check('deployed card composition sorted', JSON.stringify(deployed.elements) === '["fire"]' && JSON.stringify(deployed.chess_pieces) === '["pawn"]');
    await shot('02_card_installed');

    // ═══ RELIC flow: modifier effect ═══
    await clickTab('Relics'); await clickNew();
    await setFld('ID', 'ui_warhorn'); await setFld('Name', 'War Horn');
    await setFld('Shop price (gold)', 120);
    await clickBtn('+ add effect');
    await page.evaluate(() => {
      const sel = document.querySelector('#form-col .fx-card select');
      sel.value = 'modifier'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(120);
    await setFld('Change by', 2);
    js = await jsonPreview();
    check('relic modifier json', js.includes('"modifier"') && js.includes('"unit.attack"') && js.includes('"amount": 2'), js);
    await save(); await install();
    check('relic installed', fs.existsSync(path.join(SANDBOX, 'data/relics/tool_relic_ui_warhorn.json')));
    await shot('03_relic');

    // ═══ STATUS flow: stacking DoT ═══
    await clickTab('Statuses'); await clickNew();
    await setFld('ID', 'ui_burning'); await setFld('Name', 'Burning');
    await setFld('Wears off by', 'stacks');
    await setFld('Re-applying', 'stack');
    await clickBtn('+ add effect');
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const trig = get('When').querySelector('select');
      trig.value = 'on_turn_start'; trig.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(80);
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const attr = get('Change stat').querySelector('select');
      attr.value = 'health'; attr.dispatchEvent(new Event('change', { bubbles: true }));
      const amt = get('By').querySelector('input');
      amt.value = '-1'; amt.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await sleep(80);
    js = await jsonPreview();
    check('status json shape', js.includes('"decay": "stacks"') && js.includes('"stacking": "stack"') && js.includes('"amount": -1'), js);
    await save(); await install();
    check('status installed', fs.existsSync(path.join(SANDBOX, 'data/statuses/tool_status_ui_burning.json')));
    await shot('04_status');

    // ═══ ABILITY flow — uses the new workspace status in its payload ═══
    await clickTab('Abilities'); await clickNew();
    await setFld('ID', 'ui_ignite'); await setFld('Name', 'Ignite');
    await setFld('Mana', 2);
    await clickBtn('+ add effect');
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const pol = get('Affects').querySelector('select');
      pol.value = 'manual'; pol.dispatchEvent(new Event('change', { bubbles: true }));
      const attr = get('Change stat').querySelector('select');
      attr.value = ''; attr.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(80);
    await clickBtn('+ also apply a status');
    // pick the workspace-authored status from the dropdown
    const hasWs = await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const sel = get('Apply status').querySelector('select');
      const opt = [...sel.options].find(o => o.value === 'ui_burning');
      if (!opt) return false;
      sel.value = 'ui_burning'; sel.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    });
    check('workspace status offered in ability payload', hasWs);
    await sleep(80);
    js = await jsonPreview();
    check('ability json', js.includes('"mana": 2') && js.includes('"ui_burning"'), js);
    await save(); await install();
    check('ability installed', fs.existsSync(path.join(SANDBOX, 'data/abilities/tool_ability_ui_ignite.json')));
    await shot('05_ability');

    // ═══ CHARM flow ═══
    await clickTab('Charms'); await clickNew();
    await setFld('ID', 'ui_flame_bead'); await setFld('Name', 'Flame Bead');
    await setFld('Attack', 1);
    js = await jsonPreview();
    check('charm stats json', js.includes('"attack": 1'), js);
    await save(); await install();
    check('charm installed', fs.existsSync(path.join(SANDBOX, 'data/charms/tool_charm_ui_flame_bead.json')));
    await shot('06_charm');

    // ═══ UPGRADE TREE flow: two nodes with a requirement ═══
    await clickTab('Upgrades'); await clickNew();
    await setFld('ID', 'ui_pyromancy'); await setFld('Name', 'Pyromancy');
    await clickBtn('+ add node');
    await page.evaluate(() => {
      const node = document.querySelector('#form-col .fx-card');
      const get = lab => [...node.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const id = get('Node id').querySelector('input'); id.value = 'pyro_root'; id.dispatchEvent(new Event('input', { bubbles: true }));
      const nm = get('Name').querySelector('input'); nm.value = 'Kindling'; nm.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.evaluate(() => {
      const addFx = [...document.querySelectorAll('#form-col .fx-card button')].find(b => b.textContent.trim() === '+ add effect');
      addFx.click();
    });
    await sleep(120);
    await page.evaluate(() => {
      const fx = document.querySelector('#form-col .fx-card .fx-card');
      const kind = fx.querySelector('select');
      kind.value = 'modifier'; kind.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(120);
    await page.evaluate(() => {
      const fx = document.querySelector('#form-col .fx-card .fx-card');
      const get = lab => [...fx.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const key = get('What number').querySelector('select');
      key.value = 'mana.initial'; key.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(80);
    // second node requiring the first
    await clickBtn('+ add node');
    await page.evaluate(() => {
      const nodes = document.querySelectorAll('#form-col .fgroup > .fx-card');
      const node = nodes[nodes.length - 1];
      const get = lab => [...node.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const id = get('Node id').querySelector('input'); id.value = 'pyro_deep'; id.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await sleep(80);
    // requires-chips render on the NEXT rebuild; force one by re-clicking add+remove? Instead
    // set requires directly through a chip once visible after save-triggered rerender.
    js = await jsonPreview();
    check('upgrade json has both nodes', js.includes('pyro_root') && js.includes('pyro_deep'), js);
    check('upgrade node effect key', js.includes('mana.initial'), js);
    await save(); await install();
    check('upgrade installed', fs.existsSync(path.join(SANDBOX, 'data/upgrades/tool_upgrade_ui_pyromancy.json')));
    await shot('07_upgrade');

    // ═══ ENCOUNTER flow ═══
    await clickTab('Encounters'); await clickNew();
    await setFld('ID', 'ui_goblin_rush');
    await setFld('Serves node type', 'combat');
    await page.evaluate(() => {
      const b = [...document.querySelectorAll('#form-col button')].find(x => x.textContent.trim() === '+ add card');
      b.click();
    });
    await sleep(120);
    js = await jsonPreview();
    check('encounter pool auto-picked a card', js.includes('"enemy_pool"') && js.includes('"id"'), js);
    await save(); await install();
    const encFile = path.join(SANDBOX, 'data/encounters/tool_encounter_ui_goblin_rush.json');
    check('encounter installed', fs.existsSync(encFile));
    await shot('08_encounter');

    // ═══ NODE WEIGHTS flow ═══
    await clickTab('Map Nodes'); await clickNew();
    await setFld('ID', 'ui_eventful');
    await page.evaluate(() => {
      const band = document.querySelector('#form-col .fx-card');
      const get = lab => [...band.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const ev = get('event').querySelector('input');
      ev.value = '0.4'; ev.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await sleep(80);
    await save(); await install();
    const nwFile = path.join(SANDBOX, 'data/map/tool_nodeweights_ui_eventful.json');
    check('nodeweights installed', fs.existsSync(nwFile));
    check('nodeweights deployed raw array', Array.isArray(JSON.parse(fs.readFileSync(nwFile, 'utf8'))));
    await shot('09_nodeweights');

    // ═══ edit an existing item: reopen the card, bump attack, reinstall ═══
    await clickTab('Cards');
    await page.evaluate(() => {
      [...document.querySelectorAll('.item-row')].find(r => r.textContent.includes('ui_ember_stinger')).click();
    });
    await sleep(200);
    await setFld('Attack', 4);
    await save();
    await page.evaluate(() => document.getElementById('update-btn').click());
    await sleep(500);
    const re = JSON.parse(fs.readFileSync(cardFile, 'utf8'));
    check('edit + push-update pushes changes', re.attack === 4);
    check('still installed after update', fs.existsSync(cardFile));

    // ═══ MODIFIER with a condition: "+1 health to pawn units" on a relic ═══
    await clickTab('Relics'); await clickNew();
    await setFld('ID', 'ui_pawn_banner'); await setFld('Name', 'Pawn Banner');
    await clickBtn('+ add effect');
    await page.evaluate(() => {
      const sel = document.querySelector('#form-col .fx-card select');
      sel.value = 'modifier'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(120);
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const key = get('What number').querySelector('select');
      key.value = 'unit.health'; key.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(80);
    await clickBtn('+ add target condition');
    await page.evaluate(() => {
      const cond = document.querySelector('#form-col .cond-card');
      const kind = cond.querySelector('select');
      kind.value = 'composition'; kind.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(120);
    // default composition ['king'] → toggle king off, pawn on
    await page.evaluate(() => {
      const cond = document.querySelector('#form-col .cond-card');
      [...cond.querySelectorAll('.chip')].find(c => c.textContent === 'King').click();
      [...cond.querySelectorAll('.chip')].find(c => c.textContent === 'Pawn').click();
    });
    await sleep(80);
    js = await jsonPreview();
    check('conditioned modifier json', js.includes('"unit.health"') && js.includes('"composition"') && js.includes('"pawn"'), js);
    check('conditioned modifier summary', (await summary()).includes('only for cards'));
    await save();
    check('conditioned modifier valid', (await page.evaluate(() => document.getElementById('validation-msg').textContent)).includes('ready to install'));
    await shot('11_conditioned_modifier');

    // ═══ ENEMY CAPTAIN authoring ═══
    await clickTab('Cards'); await clickNew();
    await setFld('ID', 'ui_rat_king'); await setFld('Name', 'Rat King');
    await page.evaluate(() => {
      const boxes = [...document.querySelectorAll('#form-col label.check')];
      boxes.find(b => b.textContent.includes('King unit')).querySelector('input').click();
      boxes.find(b => b.textContent.includes('Enemy-only')).querySelector('input').click();
    });
    await sleep(100);
    await save(); await install();
    const captainFile = path.join(SANDBOX, 'data/cards/tool_card_ui_rat_king.json');
    check('enemy captain installed', fs.existsSync(captainFile));
    const captain = JSON.parse(fs.readFileSync(captainFile, 'utf8'));
    check('captain flags deployed', captain.is_king === true && captain.enemy_only === true);
    // the new captain is offered as an enemy king for encounters
    await clickTab('Encounters');
    await page.evaluate(() => {
      [...document.querySelectorAll('.item-row')].find(r => r.textContent.includes('ui_goblin_rush')).click();
    });
    await sleep(250);
    const captainOffered = await page.evaluate(() => {
      const get = lab => [...document.querySelectorAll('#form-col .fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const sel = get('Enemy King / Captain').querySelector('select');
      return [...sel.options].some(o => o.value === 'ui_rat_king');
    });
    check('workspace captain offered in encounter king picker', captainOffered);
    await clickTab('Cards');
    await page.evaluate(() => {
      [...document.querySelectorAll('.item-row')].find(r => r.textContent.includes('ui_rat_king')).click();
    });
    await sleep(250);
    await page.evaluate(() => document.getElementById('install-btn').click());   // uninstall
    await sleep(300);
    await page.evaluate(() => document.getElementById('delete-btn').click());
    await sleep(400);

    // ═══ EDIT EXISTING GAME CONTENT: bump the sandbox pawn, apply, restore ═══
    await clickTab('Cards');
    check('game tree groups by file, collapsed by default', await page.evaluate(() =>
      document.querySelectorAll('.tree-file').length >= 1 &&
      document.querySelectorAll('.item-row.tree-leaf').length === 0));
    await page.evaluate(() => {
      [...document.querySelectorAll('.tree-file')].find(f => f.textContent.includes('base.json')).click();
    });
    await sleep(200);
    check('expanding a file node reveals its entries', await page.evaluate(() =>
      document.querySelectorAll('.item-row.tree-leaf').length === 3));
    check('installed art thumbnails in the tree', await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.item-row.tree-leaf')];
      const pawn = rows.find(r => r.querySelector('.item-id').textContent === 'pawn');
      const warlord = rows.find(r => r.querySelector('.item-id').textContent === 'goblin_warlord');
      return pawn.querySelector('img.thumb') != null && warlord.querySelector('img.thumb') == null;
    }));
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.item-row.tree-leaf')];
      rows.find(r => r.querySelector('.item-id') && r.querySelector('.item-id').textContent === 'pawn').click();
    });
    await sleep(400);
    check('game edit mode banner', (await page.evaluate(() => document.getElementById('install-info').textContent)).includes('GAME content'));
    check('game mode hides install', await page.evaluate(() => document.getElementById('install-btn').hidden));
    check('art panel presents the installed game art', await page.evaluate(() => {
      const panel = document.getElementById('art-panel');
      return panel.textContent.includes('In-game art — assets/cards/pawn.png') &&
        [...panel.querySelectorAll('img')].some(i => i.src.includes('/gameart/assets/cards/pawn.png'));
    }));
    // style prompt + presets + reference checkbox
    check('use-current-art checkbox enabled when art exists', await page.evaluate(() => {
      const box = [...document.querySelectorAll('#art-panel label.check')]
        .find(l => l.textContent.includes('Use current art as input'));
      return box && !box.querySelector('input').disabled && box.textContent.includes('in-game art');
    }));
    await page.evaluate(() => {
      const ta = [...document.querySelectorAll('#art-panel textarea')][1];   // style field
      ta.value = 'ui-test style, cartoon';
      ta.dispatchEvent(new Event('input', { bubbles: true }));
      window.prompt = () => 'ui_toon';
      [...document.querySelectorAll('#art-panel button')].find(b => b.textContent.includes('save preset')).click();
    });
    await sleep(600);
    let st = await (await fetch(BASE + '/api/state')).json();
    check('style + preset persisted server-side', st.settings.artStyle === 'ui-test style, cartoon'
      && st.settings.stylePresets.ui_toon === 'ui-test style, cartoon');
    // shared across items: open another tab/item, style field carries the same text
    await clickTab('Relics');
    await page.evaluate(() => {
      [...document.querySelectorAll('.item-row')].find(r => r.textContent.includes('ui_warhorn')).click();
    });
    await sleep(250);
    check('style shared across items', await page.evaluate(() =>
      [...document.querySelectorAll('#art-panel textarea')][1].value === 'ui-test style, cartoon'));
    await page.evaluate(async () => {
      await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ artStyle: '', stylePresets: {} }) });
    });
    await clickTab('Cards');
    await page.evaluate(() => {
      const f = [...document.querySelectorAll('.tree-file')].find(x => x.textContent.includes('base.json'));
      if (f && !f.classList.contains('open')) f.click();
    });
    await sleep(150);
    await page.evaluate(() => {
      [...document.querySelectorAll('.item-row.tree-leaf')]
        .find(r => r.querySelector('.item-id').textContent === 'pawn').click();
    });
    await sleep(300);
    await setFld('Attack', 9);
    await shot('12_game_edit');
    await page.evaluate(() => document.getElementById('update-btn').click());   // Apply to game
    await sleep(500);
    let sandboxBase = JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8'));
    check('game card edited through UI', sandboxBase.find(c => c.id === 'pawn').attack === 9);
    check('restore button appears', await page.evaluate(() => !document.getElementById('delete-btn').hidden &&
      document.getElementById('delete-btn').textContent === 'Restore original'));
    await page.evaluate(() => document.getElementById('delete-btn').click());   // Restore original
    await sleep(500);
    sandboxBase = JSON.parse(fs.readFileSync(path.join(SANDBOX, 'data/cards/base.json'), 'utf8'));
    check('game card restored through UI', sandboxBase.find(c => c.id === 'pawn').attack === 1);
    await shot('13_game_restored');

    // ═══ uninstall everything from the UI ═══
    const all = [['Cards', 'ui_ember_stinger'], ['Relics', 'ui_warhorn'], ['Statuses', 'ui_burning'],
      ['Abilities', 'ui_ignite'], ['Charms', 'ui_flame_bead'], ['Upgrades', 'ui_pyromancy'],
      ['Encounters', 'ui_goblin_rush'], ['Map Nodes', 'ui_eventful']];
    for (const [tab, id] of all) {
      await clickTab(tab);
      await page.evaluate(i => {
        [...document.querySelectorAll('.item-row')].find(r => r.textContent.includes(i)).click();
      }, id);
      await sleep(200);
      await page.evaluate(() => document.getElementById('install-btn').click());
      await sleep(300);
    }
    let leftovers = [];
    for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map'])
      for (const f of fs.readdirSync(path.join(SANDBOX, d)))
        if (f.startsWith('tool_')) leftovers.push(d + '/' + f);
    check('UI uninstall left game pristine', leftovers.length === 0, leftovers.join(', '));
    await shot('10_after_uninstall');

    check('no page errors during the whole run', errors.length === 0, errors.slice(0, 5).join(' | '));
  } catch (e) {
    failures++;
    console.log('FAIL  (exception) ' + e.message);
    await shot('99_failure');
  } finally {
    await browser.close();
    server.kill();
    fs.rmSync(SANDBOX, { recursive: true, force: true });
    fs.rmSync(WS_DIR, { recursive: true, force: true });
  }
  console.log(failures ? `\n${failures} FAILURE(S)` : '\nALL PASS');
  process.exit(failures ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
