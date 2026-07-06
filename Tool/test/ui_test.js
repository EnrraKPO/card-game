/* ui_test.js — drives the real UI in Chrome through the authoring flows, against a
 * SANDBOX game root and an isolated tool workspace. The model under test: one list (the
 * game's data files), one Save-to-game verb, Enabled kill-switch, Revert, set generator.
 * Screenshots land in test/shots/. Run: node test/ui_test.js */
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

for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map', 'assets/cards'])
  fs.mkdirSync(path.join(SANDBOX, d), { recursive: true });
fs.writeFileSync(path.join(SANDBOX, 'data/cards/base.json'), JSON.stringify([
  { id: 'pawn', display_name: 'Pawn', cost: 1, attack: 1, health: 2, speed: 3, chess_pieces: ['pawn'] },
]));
fs.writeFileSync(path.join(SANDBOX, 'data/statuses/poison.json'), JSON.stringify({ id: 'poison', display_name: 'Poison' }));
fs.writeFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'),
  Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64'));
fs.mkdirSync(SHOTS, { recursive: true });

let failures = 0;
function check(name, cond, extra) {
  if (cond) console.log('  ok  ' + name);
  else { failures++; console.log('FAIL  ' + name + (extra ? ' — ' + extra : '')); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const readSbox = rel => JSON.parse(fs.readFileSync(path.join(SANDBOX, rel), 'utf8'));

async function main() {
  const server = spawn(process.execPath, [path.join(TOOL, 'server.js'), String(PORT)], {
    env: Object.assign({}, process.env, { CARDGAME_ROOT: SANDBOX, CARDGAME_WORKSPACE: WS_DIR }), stdio: 'ignore',
  });
  await sleep(700);
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--window-size=1600,1000'] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1600, height: 1000 });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('dialog', d => d.accept());
  const shot = n => page.screenshot({ path: path.join(SHOTS, n + '.png') });

  async function clickTab(label) {
    await page.evaluate(l => {
      [...document.querySelectorAll('#type-tabs button')].find(b => b.textContent.includes(l)).click();
    }, label);
    await sleep(150);
  }
  async function setFld(labelText, value) {
    const ok = await page.evaluate((lab, val) => {
      const fld = [...document.querySelectorAll('#form-col .fld')]
        .find(f => { const s = f.querySelector('span.lab'); return s && s.textContent === lab; });
      if (!fld) return false;
      const inp = fld.querySelector('input, textarea, select');
      if (!inp) return false;
      if (inp.tagName === 'SELECT') { inp.value = val; inp.dispatchEvent(new Event('change', { bubbles: true })); }
      else { inp.value = val; inp.dispatchEvent(new Event('input', { bubbles: true })); inp.dispatchEvent(new Event('change', { bubbles: true })); }
      return true;
    }, labelText, String(value));
    if (!ok) throw new Error('field not found: ' + labelText);
    await sleep(60);
  }
  async function clickBtn(text) {
    const ok = await page.evaluate(t => {
      const b = [...document.querySelectorAll('button')].find(x => x.textContent.trim() === t && !x.disabled);
      if (!b) return false;
      b.click(); return true;
    }, text);
    if (!ok) throw new Error('button not found/disabled: ' + text);
    await sleep(200);
  }
  // Save to game; if the file-picker modal opens (new entries), type/choose the file.
  async function saveToGame(newFile) {
    await page.click('#save-btn');
    await sleep(300);
    const modalOpen = await page.evaluate(() => !!document.querySelector('.modal'));
    if (modalOpen) {
      if (newFile) {
        await page.evaluate(f => {
          const inp = [...document.querySelectorAll('.modal input[type=text]')].pop();
          inp.value = f; inp.dispatchEvent(new Event('input', { bubbles: true }));
        }, newFile);
      }
      await page.evaluate(() => {
        [...document.querySelectorAll('.modal button')].find(b => b.textContent === 'Save here').click();
      });
      await sleep(400);
    }
  }
  async function openEntry(file, id) {
    await page.evaluate((f, i) => {
      const node = [...document.querySelectorAll('.tree-file')].find(x => x.textContent.includes(f));
      if (node && !node.classList.contains('open')) node.click();
    }, file, id);
    await sleep(200);
    await page.evaluate(i => {
      [...document.querySelectorAll('.item-row.tree-leaf')]
        .find(r => r.querySelector('.item-id') && r.querySelector('.item-id').textContent === i).click();
    }, id);
    await sleep(400);
  }
  const jsonPreview = () => page.evaluate(() => document.getElementById('json-preview').textContent);

  try {
    await page.goto(BASE, { waitUntil: 'networkidle0' });
    await sleep(400);
    await shot('00_landing');
    check('app loads with the game tree as THE list', await page.evaluate(() =>
      document.querySelectorAll('.tree-file').length >= 1 && !document.body.textContent.includes('Game content')));

    // ═══ CREATE: new card, full trigger/target builders, save into a NEW file ═══
    await clickTab('Cards');
    await page.click('#new-item-btn'); await sleep(200);
    await setFld('ID', 'ui_stinger'); await setFld('Name', 'Stinger');
    await setFld('Mana cost', 2); await setFld('Attack', 3); await setFld('Health', 3); await setFld('Speed', 5);
    await clickBtn('+ add effect');
    await page.evaluate(() => {   // When → attack (dual event)
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent.trim().startsWith(lab));
      const when = get('When').querySelector('select');
      when.value = 'attack'; when.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(150);
    await page.evaluate(() => {   // Affects → participant / destination
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const sel = get('Affects').querySelector('select');
      sel.value = 'participant'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(150);
    await page.evaluate(() => {
      const card = document.querySelector('#form-col .fx-card');
      const get = lab => [...card.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const sel = get('Which participant').querySelector('select');
      sel.value = 'destination'; sel.dispatchEvent(new Event('change', { bubbles: true }));
      const stat = get('Change stat').querySelector('select');
      stat.value = ''; stat.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(150);
    await clickBtn('+ also apply a status');
    const js = await jsonPreview();
    check('builders author the native resolver forms',
      js.includes('"dual_event"') && js.includes('"participant": "destination"') && js.includes('"poison"'), js);
    await saveToGame('ui_units.json');
    check('new entry saved into its chosen new file', fs.existsSync(path.join(SANDBOX, 'data/cards/ui_units.json'))
      && readSbox('data/cards/ui_units.json')[0].id === 'ui_stinger');
    check('status line shows the entry home', (await page.evaluate(() =>
      document.getElementById('install-info').textContent)).includes('data/cards/ui_units.json'));
    await shot('01_created');

    // ═══ EDIT a game-native entry + REVERT ═══
    await openEntry('base.json', 'pawn');
    check('in-game art shown for game entries', await page.evaluate(() =>
      document.getElementById('art-panel').textContent.includes('assets/cards/pawn.png')));
    await setFld('Attack', 9);
    await saveToGame();
    check('edit landed in the real file', readSbox('data/cards/base.json')[0].attack === 9);
    check('Revert appears', await page.evaluate(() => !document.getElementById('revert-btn').hidden));
    await page.click('#revert-btn'); await sleep(500);
    check('Revert restores the original', readSbox('data/cards/base.json')[0].attack === 1);

    // ═══ ENABLED kill-switch ═══
    await openEntry('ui_units.json', 'ui_stinger');
    await page.evaluate(() => { document.getElementById('enabled-check').click(); });
    await sleep(150);
    check('status line flags disabled', (await page.evaluate(() =>
      document.getElementById('install-info').textContent)).includes('disabled'));
    await saveToGame();
    check('enabled:false persisted to the file', readSbox('data/cards/ui_units.json')[0].enabled === false);
    await page.evaluate(() => { document.getElementById('enabled-check').click(); });
    await sleep(100);
    await saveToGame();
    check('re-enabling drops the flag', readSbox('data/cards/ui_units.json')[0].enabled === undefined);
    await shot('02_enabled_toggle');

    // ═══ SET GENERATOR → one normally-named file, entries individually editable ═══
    await page.click('#gen-set-btn'); await sleep(200);
    await page.evaluate(() => {
      const modal = document.querySelector('.modal');
      const get = lab => [...modal.querySelectorAll('.fld')].find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === lab);
      const a = get('Element A').querySelector('select'); a.value = 'air'; a.dispatchEvent(new Event('change', { bubbles: true }));
      const b = get('Element B').querySelector('select'); b.value = 'earth'; b.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(150);
    check('generator previews the family', await page.evaluate(() =>
      document.querySelector('.modal').textContent.includes('20 new cards')));
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal button')].find(b => b.textContent === 'Generate cards').click();
    });
    await sleep(1500);
    const setFile = path.join(SANDBOX, 'data/cards/air_earth_units.json');
    check('family written into ONE normally-named file', fs.existsSync(setFile) && readSbox('data/cards/air_earth_units.json').length === 20);
    await openEntry('air_earth_units.json', 'air_earth_pawn');
    check('set entry opens as an ordinary card', await page.evaluate(() =>
      document.getElementById('item-title').textContent.includes('Card —')));
    await shot('03_set_generator');

    // ═══ DELETE an entry ═══
    await openEntry('ui_units.json', 'ui_stinger');
    await page.click('#delete-btn'); await sleep(400);
    check('delete removes entry (and empty file)', !fs.existsSync(path.join(SANDBOX, 'data/cards/ui_units.json')));

    // ═══ art panel model picker basics ═══
    await openEntry('base.json', 'pawn');
    check('model picker lists all architectures', await page.evaluate(() => {
      const sel = [...document.querySelectorAll('#art-panel .fld')]
        .find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === 'Model');
      return sel && [...sel.querySelector('select').options].map(o => o.value).join(',') === 'flux2,krea2,ideogram4,novacartoon';
    }));

    // ═══ Krea2 is the default model, reference modes ═══
    check('krea2 is the default model with its profile', await page.evaluate(() => {
      const sel = [...document.querySelectorAll('#art-panel .fld')]
        .find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === 'Model').querySelector('select');
      const steps = [...document.querySelectorAll('#art-panel .fld')]
        .find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === 'Steps').querySelector('input');
      return sel.value === 'krea2' && steps.value === '8';
    }));
    check('card auto-prompt avoids card/tcg and effect text', await page.evaluate(() => {
      const ph = document.querySelector('#art-panel textarea').placeholder;
      return ph.startsWith('auto: ') && !/card|tcg/i.test(ph);
    }));
    await page.evaluate(() => {
      const f = [...document.querySelectorAll('#art-panel .fld')]
        .find(fl => fl.querySelector('.lab') && fl.querySelector('.lab').textContent === 'Reference image');
      const sel = f.querySelector('select');
      sel.value = 'current'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(150);
    check('krea2 refMode selector appears with both modes', await page.evaluate(() => {
      const f = [...document.querySelectorAll('#art-panel .fld')]
        .find(fl => fl.querySelector('.lab') && fl.querySelector('.lab').textContent === 'Reference mode');
      return f && [...f.querySelector('select').options].map(o => o.value).join(',') === 'img2img,reference';
    }));
    check('denoise field shown for img2img mode', await page.evaluate(() =>
      [...document.querySelectorAll('#art-panel .fld .lab')].some(l => l.textContent === 'Denoise')));
    await page.evaluate(() => {
      const f = [...document.querySelectorAll('#art-panel .fld')]
        .find(fl => fl.querySelector('.lab') && fl.querySelector('.lab').textContent === 'Reference mode');
      const sel = f.querySelector('select');
      sel.value = 'reference'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(150);
    check('denoise field hidden for reference mode', await page.evaluate(() =>
      ![...document.querySelectorAll('#art-panel .fld .lab')].some(l => l.textContent === 'Denoise')));
    await page.evaluate(() => {
      const f = [...document.querySelectorAll('#art-panel .fld')]
        .find(fl => fl.querySelector('.lab') && fl.querySelector('.lab').textContent === 'Reference image');
      const sel = f.querySelector('select');
      sel.value = 'upload'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(150);
    check('external reference file input appears', await page.evaluate(() =>
      !!document.querySelector('#art-panel input[type=file]')));

    // ═══ flip horizontally: in-game art → flipped WORKSPACE copy (not deployed) ═══
    const gameArtBytes = fs.readFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'));
    await page.evaluate(() => {
      [...document.querySelectorAll('#art-panel button')].find(b => b.textContent.includes('Flip horizontally')).click();
    });
    await sleep(600);
    const wsFlip = path.join(WS_DIR, 'art', 'card', 'pawn.png');
    check('flip writes a workspace copy', fs.existsSync(wsFlip));
    check('flip does not touch the in-game art',
      fs.readFileSync(path.join(SANDBOX, 'assets/cards/pawn.png')).equals(gameArtBytes));
    check('flipped art shows the deploy button', await page.evaluate(() =>
      [...document.querySelectorAll('#art-panel button')].some(b => b.textContent.includes('Use in game'))));

    // ═══ ✨ LLM prompt fills the field (against a fake Ollama) ═══
    const fakeOllama = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => { rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ response: 'a lone pawn soldier at dawn, painterly' })); });
    });
    await new Promise(ok => fakeOllama.listen(8480, ok));
    await page.evaluate(async () => {
      await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ollamaUrl: 'http://127.0.0.1:8480' }) });
      [...document.querySelectorAll('#art-panel button')].find(b => b.textContent.includes('✨')).click();
    });
    await sleep(800);
    check('llm button fills the prompt field', await page.evaluate(() =>
      document.querySelector('#art-panel textarea').value === 'a lone pawn soldier at dawn, painterly'));
    fakeOllama.close();

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
