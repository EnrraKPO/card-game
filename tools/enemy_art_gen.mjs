#!/usr/bin/env node
// Batch card-art generator against a local ComfyUI — the enemy-set content pipeline's
// image half. Builds the same Krea 2 Turbo graph the Tool uses (Tool/workflows/
// krea2_turbo.json), queues one job per manifest entry, and saves each result PNG.
//
//   node tools/enemy_art_gen.mjs <manifest.json> <outdir>
//
// Manifest: [{ "id": "slime_green", "prompt": "..." }, ...]. The shared STYLE fragment is
// appended to every prompt. Existing <outdir>/<id>.png files are skipped, so re-running a
// manifest only fills the gaps (delete a file to regenerate it). Prints one line per image
// with the seed used (stamp it into the card's tool.art.last for reproducibility).

const COMFY = process.env.COMFY_URL || 'http://127.0.0.1:8000';
const STYLE = 'cartoon art style, 2d illustration, clean bold outlines, dramatic volumetric light, fantasy game illustration, chibi cartoon style. detailed background scene, neat, clear,';
const WIDTH = 1024, HEIGHT = 1536, STEPS = 8, CFG = 1;

import fs from 'fs';
import path from 'path';

function buildGraph(prompt, seed) {
  return {
    '10': { class_type: 'UNETLoader', inputs: { unet_name: 'krea2_turbo_bf16.safetensors', weight_dtype: 'default' } },
    '11': { class_type: 'CLIPLoader', inputs: { clip_name: 'qwen3vl_4b_bf16.safetensors', type: 'krea2' } },
    '12': { class_type: 'VAELoader', inputs: { vae_name: 'qwen_image_vae.safetensors' } },
    '20': { class_type: 'CLIPTextEncode', inputs: { text: prompt, clip: ['11', 0] } },
    '21': { class_type: 'ConditioningZeroOut', inputs: { conditioning: ['20', 0] } },
    '34': { class_type: 'EmptyLatentImage', inputs: { width: WIDTH, height: HEIGHT, batch_size: 1 } },
    '40': { class_type: 'KSampler', inputs: { model: ['10', 0], positive: ['20', 0], negative: ['21', 0],
      latent_image: ['34', 0], seed, steps: STEPS, cfg: CFG, sampler_name: 'euler', scheduler: 'simple', denoise: 1 } },
    '50': { class_type: 'VAEDecode', inputs: { samples: ['40', 0], vae: ['12', 0] } },
    '60': { class_type: 'SaveImage', inputs: { images: ['50', 0], filename_prefix: 'enemyset' } },
  };
}

async function queue(graph) {
  const res = await fetch(`${COMFY}/prompt`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: graph }),
  });
  if (!res.ok) throw new Error(`queue failed: ${res.status} ${await res.text()}`);
  return (await res.json()).prompt_id;
}

async function waitFor(promptId) {
  for (;;) {
    const res = await fetch(`${COMFY}/history/${promptId}`);
    const hist = await res.json();
    const entry = hist[promptId];
    if (entry) {
      if (entry.status && entry.status.status_str === 'error')
        throw new Error(`generation errored: ${JSON.stringify(entry.status.messages || [])}`);
      const outputs = entry.outputs || {};
      for (const node of Object.values(outputs))
        if (node.images && node.images.length) return node.images[0];
    }
    await new Promise(r => setTimeout(r, 1500));
  }
}

async function download(img, dest) {
  const q = new URLSearchParams({ filename: img.filename, subfolder: img.subfolder || '', type: img.type || 'output' });
  const res = await fetch(`${COMFY}/view?${q}`);
  if (!res.ok) throw new Error(`view failed: ${res.status}`);
  fs.writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
}

async function main() {
  const [manifestPath, outdir] = process.argv.slice(2);
  if (!manifestPath || !outdir) {
    console.error('usage: node tools/enemy_art_gen.mjs <manifest.json> <outdir>');
    process.exit(1);
  }
  fs.mkdirSync(outdir, { recursive: true });
  // strip a UTF-8 BOM — PowerShell 5.1's `-Encoding utf8` writes one
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8').replace(/^﻿/, ''));
  for (const entry of manifest) {
    const dest = path.join(outdir, `${entry.id}.png`);
    if (fs.existsSync(dest)) { console.log(`skip  ${entry.id} (exists)`); continue; }
    const seed = Math.floor(Math.random() * 0xffffffff);
    const prompt = `${entry.prompt} ${STYLE}`;
    const t0 = Date.now();
    const img = await waitFor(await queue(buildGraph(prompt, seed)));
    await download(img, dest);
    console.log(`done  ${entry.id}  seed=${seed}  ${(Date.now() - t0) / 1000 | 0}s`);
  }
}

main().catch(e => { console.error(e.message || e); process.exit(1); });
