#!/usr/bin/env node
/*
 * Regenerates the example ComfyUI workflow JSON files in this folder from the SAME
 * buildFluxWorkflow() the Tool server actually uses to queue art — so these files can never
 * drift from what the app really sends. Run: node Tool/workflows/generate.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { buildFluxWorkflow, buildKrea2Workflow, buildIdeogram4Workflow, buildNovaCartoonWorkflow } = require('../server.js');

const OUT = __dirname;
const TURBO_LORA = 'Flux_2-Turbo-LoRA_comfyui.safetensors';   // the user's Flux 2 turbo LoRA

const variants = [
  {
    file: 'flux2_base.json',
    desc: 'Plain Flux 2 dev txt2img, 20 steps.',
    args: ['<your prompt here>', 1024, 1536, 20, 4.0, -1, 'cardgame', false],
  },
  {
    file: 'flux2_turbo.json',
    desc: `Flux 2 dev + turbo LoRA (${TURBO_LORA}), ~8 steps for a ~3x speedup.`,
    args: ['<your prompt here>', 1024, 1536, 8, 4.0, -1, 'cardgame', false, null, TURBO_LORA, 1.0],
  },
  {
    file: 'flux2_reference.json',
    desc: 'Flux 2 dev with an image reference (Kontext reference-latent path) — keeps the ' +
          'subject/character from REF_IMAGE.png while the prompt restyles it. Upload the ' +
          'reference to ComfyUI\'s input folder first (POST /upload/image) with this exact name.',
    args: ['<your restyle prompt here>', 1024, 1536, 20, 4.0, -1, 'cardgame', false, 'REF_IMAGE.png'],
  },
  {
    file: 'flux2_turbo_reference.json',
    desc: 'Both combined: turbo LoRA speed + image reference — restyle existing art fast.',
    args: ['<your restyle prompt here>', 1024, 1536, 8, 4.0, -1, 'cardgame', false, 'REF_IMAGE.png', TURBO_LORA, 1.0],
  },
];

const extraModels = [
  { file: 'krea2_turbo.json', build: () => buildKrea2Workflow('<your prompt here>', 1024, 1024, 8, 1.0, -1, 'cardgame', false) },
  {
    file: 'krea2_img2img.json',
    desc: 'Krea2 img2img: VAE-encodes REF_IMAGE.png as the starting latent, denoise 0.6 ' +
          'controls how much of it survives. Architecture-agnostic — always works. Upload ' +
          'the reference to ComfyUI\'s input folder first (POST /upload/image).',
    build: () => buildKrea2Workflow('<your restyle prompt here>', 1024, 1024, 8, 1.0, -1, 'cardgame', false, 'REF_IMAGE.png', 'img2img', 0.6),
  },
  {
    file: 'krea2_reference.json',
    desc: 'Krea2 + the Flux 2 Kontext ReferenceLatent trick, reused on the bet that Krea2 ' +
          'shares Qwen-Image\'s CLIP/VAE. Experimental — the checkpoint may not have been ' +
          'trained for it; try krea2_img2img.json if results are poor.',
    build: () => buildKrea2Workflow('<your restyle prompt here>', 1024, 1024, 8, 1.0, -1, 'cardgame', false, 'REF_IMAGE.png', 'reference'),
  },
  { file: 'ideogram4.json', build: () => buildIdeogram4Workflow('<your prompt here>', 1024, 1024, 20, 7.0, -1, 'cardgame', false) },
  { file: 'novacartoon_xl.json', build: () => buildNovaCartoonWorkflow('<booru tags here>', '', 832, 1216, 30, 5.0, -1, 'cardgame', false) },
];
for (const v of extraModels) {
  fs.writeFileSync(path.join(OUT, v.file), JSON.stringify({ prompt: v.build() }, null, 2) + '\n', 'utf8');
  console.log('wrote', v.file);
}

for (const v of variants) {
  // Written as the EXACT body POST /prompt expects — no extra keys, so the file can be sent
  // as-is (`curl -X POST http://127.0.0.1:8188/prompt -d @Tool/workflows/flux2_base.json`).
  // Per-file descriptions live in README.md instead of inline, to keep that contract clean.
  const body = { prompt: buildFluxWorkflow(...v.args) };
  fs.writeFileSync(path.join(OUT, v.file), JSON.stringify(body, null, 2) + '\n', 'utf8');
  console.log('wrote', v.file);
}
