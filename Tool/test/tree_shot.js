/* tree_shot.js — screenshot the game-content tree on the live server (real data). */
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
  // expand one file to show the tree interaction
  await page.evaluate(() => {
    const f = [...document.querySelectorAll('.tree-file')].find(x => x.textContent.includes('enemies_goblins'));
    if (f) f.click();
  });
  await new Promise(r => setTimeout(r, 300));
  await page.screenshot({ path: path.join(__dirname, 'shots', 'final_tree.png') });
  await browser.close();
  console.log('saved');
})();
