/* art_shot.js — screenshots of installed-art surfacing on the live server (real data). */
'use strict';
const fs = require('fs');
const path = require('path');
const puppeteer = require('puppeteer-core');
const CHROME = ['C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(fs.existsSync);

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new' });
  const page = await browser.newPage();
  await page.setViewport({ width: 1600, height: 1000 });
  await page.goto('http://127.0.0.1:8460', { waitUntil: 'networkidle0' });
  await new Promise(r => setTimeout(r, 500));
  // expand a file with real card art and open one entry
  await page.evaluate(() => {
    const f = [...document.querySelectorAll('.tree-file')].find(x => x.textContent.includes('chess_combined'));
    if (f) f.click();
  });
  await new Promise(r => setTimeout(r, 800));
  await page.screenshot({ path: path.join(__dirname, 'shots', 'final_art_tree.png') });
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll('.item-row.tree-leaf')];
    const withThumb = rows.find(r => r.querySelector('img.thumb'));
    if (withThumb) withThumb.click();
  });
  await new Promise(r => setTimeout(r, 900));
  await page.evaluate(() => document.querySelector('#art-panel').scrollIntoView());
  await new Promise(r => setTimeout(r, 400));
  await page.screenshot({ path: path.join(__dirname, 'shots', 'final_art_panel_game.png') });
  await browser.close();
  console.log('saved');
})();
