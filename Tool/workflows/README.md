# ComfyUI workflows

Reusable Flux 2 dev graphs for this project, in **API format** — the exact JSON body
`POST /prompt` expects (`{"prompt": {...node graph...}}`). They're generated straight from
`buildFluxWorkflow()` in `Tool/server.js` (see `generate.js`), so they can't drift from what
the app actually sends — verified 2026-07-05 by queueing each variant against the live
server (`flux2_base.json` and `flux2_turbo.json` both completed with `status: success`).

| File | What it is |
|---|---|
| `flux2_base.json` | Plain Flux 2 dev txt2img, 20 steps. |
| `flux2_turbo.json` | + the turbo LoRA (`Flux_2-Turbo-LoRA_comfyui.safetensors`), ~8 steps — roughly 3x faster, quality holds. |
| `flux2_reference.json` | + an image reference (Kontext reference-latent chain): keeps the subject/character from a source image while the prompt restyles it. |
| `flux2_turbo_reference.json` | Both combined — fast restyles of existing art. |

**Note on the ComfyUI app's drag-and-drop "Load":** that expects the richer *workflow* export
(node positions, links, UI metadata), which these are not. These are the *API* format — use
them by POSTing directly, or as a reference for wiring the same nodes in the graph editor.

## Use directly

```bash
curl -X POST http://127.0.0.1:8187/prompt -H "Content-Type: application/json" \
  -d @Tool/workflows/flux2_turbo.json
```

Edit the placeholder prompt text (and, for the reference variants, upload your source image
via `POST /upload/image` first and set its filename in the `LoadImage` node) before queueing.

## Regenerate after changing the pipeline

```bash
node Tool/workflows/generate.js
```

## Other ways to drive the same pipeline

- **The Tool itself** (`Tool/server.js`, http://127.0.0.1:8460) — the full authoring UI, with
  the turbo/reference/style options as checkboxes and fields.
- **`tools/comfy_gen.py`** — plain txt2img CLI driver. `--turbo` folds in the same LoRA at ~8
  steps; `--lora NAME --lora-strength N` for a different one.
- **`tools/comfy_ref_gen.py`** — multi-reference-image CLI driver (same `--turbo`/`--lora`
  flags), for restyling existing art from the command line.

All four (Tool, these workflow files, and the two CLI scripts) build the identical node graph
shape — same LoRA loader, same reference-latent chain — so a technique proven in one works in
the others.
