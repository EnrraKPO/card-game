# CardGame Content Authoring Tool

A local web app for authoring the game's content — cards, relics, statuses, abilities,
charms, upgrade trees, encounters and map node weights — **directly in the game's own
data files**, plus ComfyUI art generation.

## Run it

```
node Tool/server.js          # → http://127.0.0.1:8460
```
(or double-click `run_tool.bat`). Zero runtime dependencies — plain Node.

## The model

The tool is part of the game ecosystem — seamless and organic:

- **The sidebar is `data/<type>/`** — the game's real files and their entries. There is
  no separate workspace, no install step, no tool-prefixed files.
- **One verb: Save to game.** New entries ask one question — which file (an existing one,
  or a new normally-named one). Existing entries save back where they live.
- **Enabled** is the kill-switch: a checkbox per entry (`"enabled": false` in the data);
  the game's loaders skip disabled entries. Content deactivates without leaving the file.
- **Revert** restores an entry to how it was before the tool touched it (added entries
  are removed again, deleted entries come back) — byte-exact snapshots under the hood.
  Everything else is git's job.
- **Art belongs to the item.** A finished generation deploys straight to the game's
  asset path (old art backed up); art generated before an entry's first save deploys
  with that save. Two facts of life the status line reminds you of: the game reads data
  at startup (restart to see changes), and new images import when the Godot editor
  regains focus once.

## Authoring UX

- Effects are built from dropdowns in the engine's native resolver schema: a trigger
  (event + ORIGIN/DESTINATION condition gates) and targets (kind + conditions), with the
  full condition grammar everywhere. "In plain words" restates the item in English;
  "Deployed JSON" shows exactly what's in the file.
- **⚙ Set…** on the Cards tab batch-creates a composition family (element pair × piece
  combos, derived stats) into one normally-named file — every entry an ordinary card.
- Server-side validation gates every save (unknown events, dangling references,
  payload-less effects…).

## Art (ComfyUI)

Model picker per generation — **Krea 2 Turbo** is the default: **Flux 2 dev**
(reference-image input + turbo LoRA), **Krea 2 Turbo** (reference-image input via two
modes — see below), **Ideogram 4**, **NovaCartoonXL** (Illustrious — booru-tag prompts,
negative-prompt field, SDXL-bucket sizes). A shared Style fragment (with named presets)
appends to every prompt. Server URL and turbo LoRA in Settings. Reusable API-format
graphs live in `Tool/workflows/` (regenerate with `node Tool/workflows/generate.js`).

**Generation never touches the game's assets.** A finished image lands in the tool
workspace only; it reaches the game when the user presses **⬆ Use in game** on the art
panel (`POST /api/art/deploy`, replaced art backed up), or automatically on a brand-new
entry's first Save (nothing to lose there). The in-game art therefore stays available as
reference input across any number of regenerations.

**⇋ Flip horizontally** mirrors the current image (workspace art, or the in-game art if
that's all there is) for subjects generated facing the wrong way. The browser does the
pixel work on a canvas and stores the result back via `POST /api/art/put` — always into
the workspace, so deploying a flip stays an explicit "Use in game" press.

The **Reference image** selector feeds a generation either the item's current art or an
**external image** uploaded from disk (`POST /api/art/upload-ref`, stored under
`workspace/refs/`). For Krea 2 a reference also picks a mode:
- **img2img** — the reference image is VAE-encoded straight into the starting latent and
  `denoise` (0–1) controls how much of it survives; architecture-agnostic, always works.
- **reference** — the Flux 2 Kontext trick (`ReferenceLatent` onto the positive
  conditioning), reused here on the bet that Krea2 shares Qwen-Image's CLIP/VAE.
  Experimental — the checkpoint may not have been trained for it.

Card auto-prompts deliberately never say "card"/"tcg" (the model would render a whole
framed card with stats) and never include description/effect text (it gets rendered AS
text in the image) — they build the subject from the card's name and composition instead.

**✨ LLM prompts** — the "✨ llm" button beside "↻ auto" asks a local Ollama model
(`POST /api/art/prompt`; URL + model in Settings, default `gemma4:31b` on `:11434`) to
write a rich prompt from the item's FULL data: it reads the same plain-English summary
the editor shows and is instructed to translate mechanics into visual motifs (poison →
dripping venom, heal → radiant glow) while obeying the same hard rules — never
card/frame/stats words, no readable text in the scene, staging matched to the per-type
template it receives as an example. Press again to re-roll; the result lands in the
Prompt field for editing before generation.

Types with no art slot in the game (statuses, charms, upgrades, encounters, map nodes)
still allow generation as workspace reference imagery — clearly labeled as such.

## Tests

```
node Tool/test/api_test.js   # entry-centric API, enabled flag, revert semantics, art deploy
node Tool/test/ui_test.js    # Chrome-driven: create/edit/revert/toggle/generate flows
```
Both run against a throwaway sandbox game root AND an isolated tool workspace — they
never touch the real repo.

`Tool/verify_content.tscn` (edit to taste) asserts specific content loads in-game.
