/* final_shot.js — screenshots of the live tool (real workspace content). */
'use strict';
const fs = require('fs');
const path = require('path');
const puppeteer = require('puppeteer-core');
const CHROME = ['C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(fs.existsSync);
const SHOTS = path.join(__dirname, 'shots');

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new' });
  const page = await browser.newPage();
  await page.setViewport({ width: 1600, height: 1000 });
  await page.goto('http://127.0.0.1:8460', { waitUntil: 'networkidle0' });
  await new Promise(r => setTimeout(r, 500));
  // open the frost_adept card
  await page.evaluate(() => {
    [...document.querySelectorAll('.item-row')].find(r => r.textContent.includes('frost_adept')).click();
  });
  await new Promise(r => setTimeout(r, 600));
  await page.screenshot({ path: path.join(SHOTS, 'final_card_with_art.png') });
  // scroll the side column to show art preview
  await page.evaluate(() => document.querySelector('#art-panel').scrollIntoView());
  await new Promise(r => setTimeout(r, 300));
  await page.screenshot({ path: path.join(SHOTS, 'final_art_panel.png') });
  await browser.close();
  console.log('shots saved');
})();
