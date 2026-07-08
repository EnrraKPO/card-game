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

for (const d of ['data/cards', 'data/statuses', 'data/abilities', 'data/charms', 'data/relics', 'data/upgrades', 'data/encounters', 'data/map', 'assets/cards/enemies'])
  fs.mkdirSync(path.join(SANDBOX, d), { recursive: true });
fs.writeFileSync(path.join(SANDBOX, 'data/cards/base.json'), JSON.stringify([
  { id: 'pawn', display_name: 'Pawn', cost: 1, attack: 1, health: 2, speed: 3, chess_pieces: ['pawn'] },
  { id: 'lone_pawn', display_name: 'Lone Pawn', cost: 1, attack: 1, health: 1, speed: 1, chess_pieces: ['pawn'] },
  { id: 'fire_queen', display_name: 'Fire Queen', cost: 5, attack: 5, health: 5, speed: 5, elements: ['fire'], chess_pieces: ['queen'],
    // a stored art recipe (tool.art) — the panel must auto-load it and offer ↻ Recipe
    tool: { art: { prompt: 'a regal fire queen', model: 'krea2', width: 1024, height: 1536,
      steps: 20, guidance: 4, rembg: false,
      last: { seed: 424242, prompt: 'a regal fire queen', style: '', at: '2026-07-07' } } } },
  { id: 'goblin', display_name: 'Goblin Grunt', cost: 1, attack: 2, health: 1, speed: 4, enemy_only: true },
  // owns the air+earth knight composition under a custom id — the set generator must PULL
  // this definition into the family file instead of generating a conflicting air_earth_knight
  { id: 'dust_devil', display_name: 'Dust Devil', cost: 3, attack: 4, health: 2, speed: 6, elements: ['air', 'earth'], chess_pieces: ['knight'] },
  // base combo cards = the naming vocabulary for generated set cards (Sand Paladin etc.)
  { id: 'air_earth', display_name: 'Sand', cost: 2, attack: 2, health: 2, speed: 2, elements: ['air', 'earth'], card_type: 'spell' },
  { id: 'bishop_pawn', display_name: 'Paladin', cost: 2, attack: 2, health: 3, speed: 3, chess_pieces: ['bishop', 'pawn'] },
]));
fs.writeFileSync(path.join(SANDBOX, 'data/statuses/poison.json'), JSON.stringify({ id: 'poison', display_name: 'Poison' }));
const PNG1x1_UI = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
fs.writeFileSync(path.join(SANDBOX, 'assets/cards/pawn.png'), PNG1x1_UI);
fs.writeFileSync(path.join(SANDBOX, 'assets/cards/lone_pawn.png'), PNG1x1_UI);
fs.writeFileSync(path.join(SANDBOX, 'assets/cards/fire_queen.png'), PNG1x1_UI);
fs.writeFileSync(path.join(SANDBOX, 'assets/cards/enemies/goblin.png'), PNG1x1_UI);
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
  page.on('dialog', d => d.accept(d.type() === 'prompt' ? 'uitest_preset' : undefined));
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
      document.querySelector('.modal').textContent.includes('19 new cards')));
    check('generator plans to pull the existing composition in', await page.evaluate(() =>
      /1 pulled in from other files \(dust_devil — base\.json\)/.test(document.querySelector('.modal').textContent)));
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal button')].find(b => b.textContent === 'Generate cards').click();
    });
    await sleep(1500);
    const setFile = path.join(SANDBOX, 'data/cards/air_earth_units.json');
    check('family written into ONE normally-named file', fs.existsSync(setFile) && readSbox('data/cards/air_earth_units.json').length === 20);
    const aeSet = readSbox('data/cards/air_earth_units.json');
    check('existing composition moved in verbatim, no conflicting twin generated',
      aeSet.some(e => e.id === 'dust_devil' && e.attack === 4)
      && !aeSet.some(e => e.id === 'air_earth_knight')
      && !readSbox('data/cards/base.json').some(e => e.id === 'dust_devil'));
    check('generated cards named from the base combo vocabulary',
      aeSet.find(e => e.id === 'air_earth_bishop_pawn').display_name === 'Sand Paladin'
      && aeSet.find(e => e.id === 'air_earth_pawn').display_name === 'Sand Pawn'
      && aeSet.find(e => e.id === 'air_earth_queen_rook').display_name === 'Sand Queen Rook',
      JSON.stringify(aeSet.map(e => e.display_name)));
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
    check('kin adherence dial is a labeled field', await page.evaluate(() =>
      [...document.querySelectorAll('#art-panel .fld .lab')]
        .some(l => l.textContent.includes('what carries over from the anchor'))));

    // ═══ bulk ✨: the file button opens the adherence modal (does not fire blind) ═══
    await page.evaluate(() => {
      [...document.querySelectorAll('.tree-file button')].find(b => b.textContent.trim() === '✨').click();
    });
    await sleep(250);
    check('file ✨ opens the batch modal with the adherence choice', await page.evaluate(() => {
      const m = document.querySelector('.modal');
      if (!m || !m.textContent.includes('Infer art recipes')) return false;
      const opts = [...m.querySelectorAll('select option')].map(o => o.textContent);
      const sel = m.querySelector('select');
      return opts.some(t => t.includes('Same concept')) && opts.some(t => t.includes('Replicate'))
        && sel.selectedOptions[0].textContent.includes('Same concept');   // intermediate = default
    }));
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal button')].find(b => b.textContent === 'Cancel').click();
    });
    await sleep(100);

    // ═══ ⛓ Quick Flow: appointment via settings, file batch modal, per-item button ═══
    await page.evaluate(async () => {
      await fetch('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ quickFlow: { steps: [{ model: 'flux2', samples: 1, turbo: true },
          { model: 'krea2', samples: 3, denoise: 0.55 }], anchor: 'recipe' } }) });
      await refreshState(true);
    });
    await sleep(300);
    await page.evaluate(() => {
      const row = [...document.querySelectorAll('.tree-file')].find(x => x.textContent.includes('base.json'));
      [...row.querySelectorAll('button')].find(b => b.textContent.trim() === '⛓').click();
    });
    await sleep(250);
    check('file ⛓ opens the Quick Flow modal with eligibility and the fill offer', await page.evaluate(() => {
      const m = document.querySelector('.modal');
      return m && m.textContent.includes('Quick Flow — base.json')
        && /1 card has a recipe prompt and will flow/.test(m.textContent)
        && !!m.querySelector('input[type=checkbox]')
        && ![...m.querySelectorAll('button')].find(b => b.textContent === '⛓ Run').disabled;
    }));
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal button')].find(b => b.textContent === 'Cancel').click();
    });
    await sleep(100);
    check('recipe-carrying card rows get the one-click ⛓', await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.item-row.tree-leaf')];
      const fq = rows.find(r => r.querySelector('.item-id') && r.querySelector('.item-id').textContent === 'fire_queen');
      const lp = rows.find(r => r.querySelector('.item-id') && r.querySelector('.item-id').textContent === 'lone_pawn');
      return fq && [...fq.querySelectorAll('button')].some(b => b.textContent.trim() === '⛓')
        && lp && ![...lp.querySelectorAll('button')].some(b => b.textContent.trim() === '⛓');
    }));

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
    check('card auto-prompt avoids card/tcg, effect text and canned backgrounds', await page.evaluate(() => {
      const ph = document.querySelector('#art-panel textarea').placeholder;
      return ph.startsWith('auto: ') && !/card|tcg|ornate dark background/i.test(ph);
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
    // The fake answers differently when reference images ride along, so the advanced-mode
    // test below also proves the attached refs actually reach the LLM request.
    let lastOllamaBody = null;
    const fakeOllama = require('http').createServer((rq, rs) => {
      let b = ''; rq.on('data', c => b += c);
      rq.on('end', () => {
        lastOllamaBody = JSON.parse(b);
        const withImages = (lastOllamaBody.images || []).length > 0;
        rs.setHeader('Content-Type', 'application/json');
        rs.end(JSON.stringify({ response: withImages
          ? 'a pawn styled after the references, painterly'
          : 'a lone pawn soldier at dawn, painterly' }));
      });
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

    // ═══ advanced fullscreen mode: reference browser + attach flows ═══
    await page.evaluate(() => {
      [...document.querySelectorAll('#art-panel button')].find(b => b.textContent.includes('Advanced')).click();
    });
    await sleep(500);   // modal + async reference load
    check('advanced mode opens fullscreen', await page.evaluate(() => !!document.querySelector('.modal.advanced')));
    check('llm guidance inputs live in advanced mode only', await page.evaluate(() => {
      const labs = root => [...root.querySelectorAll('.fld .lab')].map(l => l.textContent);
      return labs(document.querySelector('.modal.advanced')).some(t => t.includes('concept direction'))
        && labs(document.querySelector('.modal.advanced')).some(t => t.includes('how to use the references'))
        && !labs(document.getElementById('art-panel')).some(t => t.includes('concept direction'));
    }));
    check('reference browser ranks the bare piece version first', await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.modal.advanced .ref-row')];
      return rows.length === 3 && rows[0].textContent.includes('Lone Pawn')
        && rows.some(r => r.textContent.includes('Fire Queen'))
        && rows.some(r => r.textContent.includes('Goblin Grunt')) && !!rows[0].querySelector('img.thumb');
    }));

    // ═══ browser filters: free text + enemy/player, list rebuilds in place ═══
    const setRefFilter = async (text, enemy) => page.evaluate((t, e) => {
      const inp = document.querySelector('.modal.advanced .ref-filter input');
      inp.value = t; inp.dispatchEvent(new Event('input', { bubbles: true }));
      const sel = document.querySelector('.modal.advanced .ref-filter select');
      sel.value = e; sel.dispatchEvent(new Event('change', { bubbles: true }));
    }, text, enemy);
    await setRefFilter('fire', 'all');
    check('text filter narrows the list', await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.modal.advanced .ref-row')];
      return rows.length === 1 && rows[0].textContent.includes('Fire Queen');
    }));
    await setRefFilter('', 'enemy');
    check('enemy filter shows only enemy cards', await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.modal.advanced .ref-row')];
      return rows.length === 1 && rows[0].textContent.includes('Goblin Grunt');
    }));
    await setRefFilter('', 'player');
    check('player filter hides enemy cards', await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.modal.advanced .ref-row')];
      return rows.length === 2 && !rows.some(r => r.textContent.includes('Goblin Grunt'));
    }));
    await setRefFilter('lone', 'all');
    await page.evaluate(() => {
      const row = [...document.querySelectorAll('.modal.advanced .ref-row')].find(r => r.textContent.includes('Lone Pawn'));
      [...row.querySelectorAll('button')].find(b => b.textContent.includes('llm')).click();
    });
    await sleep(150);
    check('llm ref attaches with badge + chip', await page.evaluate(() => {
      const row = [...document.querySelectorAll('.modal.advanced .ref-row')].find(r => r.textContent.includes('Lone Pawn'));
      const strip = document.querySelector('.modal.advanced .attached-strip');
      return row && row.classList.contains('attached-llm') && strip && strip.textContent.includes('Lone Pawn');
    }));
    check('filter survives an attach re-render', await page.evaluate(() =>
      document.querySelector('.modal.advanced .ref-filter input').value === 'lone'
      && document.querySelectorAll('.modal.advanced .ref-row').length === 1));
    await setRefFilter('', 'all');
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal.advanced button')].find(b => b.textContent.includes('✨')).click();
    });
    await sleep(800);
    check('advanced ✨ sends the attached refs to the llm', await page.evaluate(() =>
      document.querySelector('.modal.advanced textarea').value === 'a pawn styled after the references, painterly'));
    check('mechanical lines (composition, stats) are hidden from the llm BY DEFAULT',
      lastOllamaBody && !lastOllamaBody.prompt.includes('Cost 1')
      && !lastOllamaBody.prompt.includes('Composition: pawn')
      && lastOllamaBody.prompt.includes('Pawn — Unit'), lastOllamaBody && lastOllamaBody.prompt);
    check('name and composition are separately toggleable lines (mech ones unticked)', await page.evaluate(() => {
      const lines = [...document.querySelectorAll('.modal.advanced .llm-line')];
      const comp = lines.find(l => l.textContent.trim() === 'Composition: pawn.');
      const name = lines.find(l => l.textContent.trim() === 'Pawn — Unit.');
      return name && name.querySelector('input').checked && comp && !comp.querySelector('input').checked;
    }));
    // ticking a mechanical line opts it back in for THIS item
    await page.evaluate(() => {
      const line = [...document.querySelectorAll('.modal.advanced .llm-line')].find(l => l.textContent.includes('Cost 1'));
      line.querySelector('input').click();
    });
    await sleep(100);
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal.advanced button')].find(b => b.textContent.includes('✨')).click();
    });
    await sleep(800);
    check('a ticked mechanical line reaches the llm', lastOllamaBody && lastOllamaBody.prompt.includes('Cost 1'),
      lastOllamaBody && lastOllamaBody.prompt);
    // untick a NORMAL line → it must vanish from the next request
    await page.evaluate(() => {
      const line = [...document.querySelectorAll('.modal.advanced .llm-line')].find(l => l.textContent.trim() === 'Pawn — Unit.');
      line.querySelector('input').click();
    });
    await sleep(100);
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal.advanced button')].find(b => b.textContent.includes('✨')).click();
    });
    await sleep(800);
    check('unticked line is hidden from the llm', lastOllamaBody && !lastOllamaBody.prompt.includes('Pawn — Unit'),
      lastOllamaBody && lastOllamaBody.prompt);
    await page.evaluate(() => {   // restore for later assertions
      const line = [...document.querySelectorAll('.modal.advanced .llm-line')].find(l => l.textContent.trim() === 'Pawn — Unit.');
      line.querySelector('input').click();
    });
    await sleep(100);
    // ═══ guidance presets: save the concept text as a preset, recall it after clearing ═══
    const conceptFld = () => [...document.querySelectorAll('.modal.advanced .fld')]
      .find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent.includes('concept direction'));
    await page.evaluate(fldFinder => {
      const fld = eval(`(${fldFinder})`)();
      const inp = fld.querySelector('input[type=text]');
      inp.value = 'grim sea witch energy';
      inp.dispatchEvent(new Event('input', { bubbles: true }));
      [...fld.querySelectorAll('button')].find(b => b.textContent.includes('save preset')).click();
    }, conceptFld.toString());
    await sleep(400);
    check('concept preset saved into the select', await page.evaluate(fldFinder => {
      const fld = eval(`(${fldFinder})`)();
      return [...fld.querySelector('select').options].some(o => o.value === 'uitest_preset');
    }, conceptFld.toString()));
    await page.evaluate(fldFinder => {
      const fld = eval(`(${fldFinder})`)();
      const inp = fld.querySelector('input[type=text]');
      inp.value = ''; inp.dispatchEvent(new Event('input', { bubbles: true }));
      const sel = fld.querySelector('select');
      sel.value = 'uitest_preset'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    }, conceptFld.toString());
    await sleep(150);
    check('concept preset recalls into the field', await page.evaluate(fldFinder => {
      const fld = eval(`(${fldFinder})`)();
      return fld.querySelector('input[type=text]').value === 'grim sea witch energy';
    }, conceptFld.toString()));

    // 🔎 match art: vision-analyzes the item's current art into a recreating prompt
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal.advanced button')].find(b => b.textContent.includes('match art')).click();
    });
    await sleep(800);
    check('match-art fills the prompt from the current art', await page.evaluate(() =>
      document.querySelector('.modal.advanced textarea').value === 'a pawn styled after the references, painterly')
      && lastOllamaBody && lastOllamaBody.images.length === 1 && /recreate/i.test(lastOllamaBody.system));
    await page.evaluate(() => {
      const row = [...document.querySelectorAll('.modal.advanced .ref-row')].find(r => r.textContent.includes('Fire Queen'));
      [...row.querySelectorAll('button')].find(b => b.textContent.includes('img')).click();
    });
    await sleep(150);
    check('game-art image ref attaches and selects the game source', await page.evaluate(() => {
      const row = [...document.querySelectorAll('.modal.advanced .ref-row')].find(r => r.textContent.includes('Fire Queen'));
      const sel = [...document.querySelectorAll('.modal.advanced .fld')]
        .find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === 'Reference image');
      return row.classList.contains('attached-img') && sel && sel.querySelector('select').value === 'game';
    }));
    await shot('04_advanced_mode');
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal.advanced button')].find(b => b.textContent.includes('Collapse')).click();
    });
    await sleep(200);
    check('collapse returns to the compact panel with refs intact', await page.evaluate(() => {
      if (document.querySelector('.modal.advanced')) return false;
      const sel = [...document.querySelectorAll('#art-panel .fld')]
        .find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent === 'Reference image');
      return sel && sel.querySelector('select').value === 'game'
        && document.querySelector('#art-panel textarea').value === 'a pawn styled after the references, painterly';
    }));
    await shot('05_after_collapse');
    fakeOllama.close();

    // ═══ per-entry art recipe (tool.art): auto-load, ↻ Recipe, save round-trip ═══
    await openEntry('base.json', 'fire_queen');
    check('stored art recipe auto-feeds the panel', await page.evaluate(() =>
      document.querySelector('#art-panel textarea').value === 'a regal fire queen'));
    check('↻ Recipe button appears with the recorded seed', await page.evaluate(() => {
      const b = [...document.querySelectorAll('#art-panel button')].find(x => x.textContent.includes('↻ Recipe'));
      return !!b && b.title.includes('424242');
    }));
    await page.evaluate(() => {
      const ta = document.querySelector('#art-panel textarea');
      ta.value = 'an ashen fire queen'; ta.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await sleep(100);
    await saveToGame();
    const fq = readSbox('data/cards/base.json').find(e => e.id === 'fire_queen');
    check('edited recipe saved onto the entry, generation stamp preserved',
      fq.tool && fq.tool.art && fq.tool.art.prompt === 'an ashen fire queen'
      && fq.tool.art.last && fq.tool.art.last.seed === 424242, JSON.stringify(fq.tool));
    // an entry with NO recipe and an untouched panel must stay metadata-free
    await openEntry('base.json', 'lone_pawn');
    await setFld('Name', 'Lone Pawn!');
    await saveToGame();
    check('untouched art panel stamps no metadata', !('tool' in
      readSbox('data/cards/base.json').find(e => e.id === 'lone_pawn')));

    // ═══ ⛓ flow modal: steps editor, presets, fan-out math ═══
    await page.evaluate(() => {
      [...document.querySelectorAll('#art-panel button')].find(b => b.textContent.includes('⛓ Flow')).click();
    });
    await sleep(400);
    check('flow modal opens with steps editor, presets and fan-out total', await page.evaluate(() => {
      const m = document.querySelector('.modal');
      if (!m || !m.textContent.includes('Multi-step generation')) return false;
      const labs = [...m.querySelectorAll('.lab')].map(l => l.textContent);
      return m.textContent.includes('Step 1') && m.textContent.includes('Step 2')
        && labs.some(t => t.includes('Flow presets'))
        && /4 images will be generated/.test(m.textContent);   // default flux×1 → krea×3
    }));
    check('flow anchor offers current art, the base piece art and an upload', await page.evaluate(() => {
      const m = document.querySelector('.modal');
      const fldEl = [...m.querySelectorAll('.fld')]
        .find(f => f.querySelector('.lab') && f.querySelector('.lab').textContent.includes('Anchor'));
      if (!fldEl) return false;
      const opts = [...fldEl.querySelectorAll('select option')].map(o => o.textContent);
      return opts.some(t => t.includes('Current art'))
        && opts.some(t => t.includes('Base piece art: Pawn'))
        && !!m.querySelector('input[type=file]');
    }));
    await page.evaluate(() => {
      [...document.querySelectorAll('.modal button')].find(b => b.textContent === 'Close').click();
    });
    await sleep(150);

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
