# CardGame Content Authoring Tool

A local web app for authoring game content — **cards, relics, statuses, abilities,
charms, upgrade trees, encounters and map node weights** — without writing JSON by
hand, plus **ComfyUI art generation** for the content that has an art slot.

## Run it

```
node Tool/server.js          # → http://127.0.0.1:8460
```
(or double-click `run_tool.bat`). Zero runtime dependencies — plain Node.

## How it works

- Everything you author lives in **`Tool/workspace/<type>/<id>.json`** — the game
  never sees it until you install.
- **Install** deploys the item as `data/<dir>/tool_<type>_<id>.json` (single file
  per item) and copies its generated art to the game's by-convention asset path
  (`assets/cards/<id>.png`, `assets/relics/<id>.png`, `assets/abilities/<id>.png`).
- **Uninstall** removes *exactly* the files that install wrote (tracked in
  `Tool/workspace/installed.json`), including Godot's `.import` sidecars.
- **Push update** re-deploys a changed item over its installed files.
- The tool never overwrites game art it didn't create (install fails with a clear
  message instead).
- Installed JSON is picked up by the game's loaders at startup — restart the game
  (or re-run the scene) after installing. New PNGs are imported when the Godot
  editor next opens the project.

## Authoring UX

- Every effect is built from dropdowns in designer language (triggers, targeting,
  conditions, modifier keys, interceptors, custom hooks) — the exact game
  vocabulary from `Effect.from_dict` / `EffectCondition.from_dict`.
- The **In plain words** panel restates the item in English; the **Deployed JSON**
  panel shows byte-for-byte what will ship.
- Dropdowns for statuses/abilities/cards include both game content *and* other
  workspace items, so a pack can reference itself before it's installed
  (e.g. a card applying a status you just authored).
- Server-side validation gates every install (unknown keys, dangling references,
  payload-less effects, inverted ranges…).

## Art (ComfyUI)

- Uses the Flux 2 dev pipeline on the server configured in **Settings**
  (default `http://127.0.0.1:8187`).
- Per-type default canvas: cards 1024×1536, relic/ability icons 1024×1024 with
  background removal (Inspyrenet), statuses/charms 512×512.
- Leave the prompt empty to auto-derive it from the item's name/description
  (`↻ auto` re-derives).
- **Style (shared)**: a second prompt fragment appended to *every* generation,
  global across all items — with named presets (save/load/delete). Use it to keep
  a consistent look, or to restyle art in bulk.
- **Use current art as input**: feeds the item's current image (in-game art when
  installed, else the generated workspace image) into Flux 2's reference-latent
  path, so the generation keeps the same subject/character — combine with a style
  preset to restyle existing card art.
- **⚡ Turbo LoRA**: a per-generation toggle that folds a speed LoRA into the UNET
  (`LoraLoaderModelOnly`) and drops to ~8 steps — roughly 3× faster with
  comparable quality; combines freely with the reference input and rembg. The
  LoRA file, default steps and strength are set in **Settings** (pre-configured to
  `Flux_2-Turbo-LoRA_comfyui.safetensors`; the field autocompletes from the
  server's LoRA list).

See `Tool/workflows/` for the same graphs exported as standalone, reusable
ComfyUI API-format JSON files (base / turbo / reference / turbo+reference), plus
`--turbo`/`--lora` flags on the `tools/comfy_gen.py` and `tools/comfy_ref_gen.py`
CLI drivers for the identical pipeline outside the web tool.
- Generated art lands in `Tool/workspace/art/<type>/<id>.png` and previews in the
  editor. It deploys on install **only** for types the game reads art for
  (cards, relics, abilities). Status pips / charm pips are glyph+colour in game,
  so their art stays workspace-only reference.
- **Installed art is always presented**: any item whose art exists in the game's
  assets (by the game's own lookup conventions, incl. `assets/cards/enemies/` and
  the ability→card fallback) shows it as a thumbnail in the item lists and as
  "In-game art" in the art panel, alongside any newly generated image.

## Editing EXISTING game content

Every type's sidebar has a **Game content** tree (with a filter box) listing the
game's own entries — grouped by source JSON file, collapsed by default; the filter
searches across all files and auto-expands matches. Includes enemy cards and
captains. Opening an entry edits it **in place**:

- **Apply to game** validates and writes the entry back into its original file
  (`data/cards/enemies_undead.json` etc.). The first apply snapshots the original,
  so **Restore original** is always available — and byte-exact (original file
  formatting included) as long as the file wasn't changed outside the tool.
- If you generated art for the item, Apply offers to replace the game art too;
  the old image is backed up and comes back on restore.
- Ids of existing content are fixed (renames would break decks/encounters).
- New content — including new enemy cards (tick *Enemy-only*, plus *King* for a
  captain; enemy art deploys to `assets/cards/enemies/`) — still goes through the
  workspace Install flow.

## Conditioned modifiers

Targeting is gated by `conditions` on every effect kind in the same form: a
card-scoped modifier can carry the same condition list triggered effects use, e.g.
"+1 Health to pawn units" (see the `pawn_vanguard` sample relic). Interceptors
don't evaluate conditions yet — that part awaits a redesign (conditions there need
to address either mutation side).

## What "Events" means here

Map "?" events (the wandering trainer / relic event) are hardcoded screens in the
game, not data. The authorable event-node surface is:
- **Encounters** — combat/elite/boss templates (enemy pool, floors, rewards).
- **Map Nodes** — floor-band weights for node types (combat/rest/event/shop),
  deployed into `data/map/`.

## Tests

```
node Tool/test/api_test.js   # full API + install/uninstall exactness (sandboxed)
node Tool/test/ui_test.js    # drives Chrome through every authoring flow (sandboxed)
```
Both run against a throwaway sandbox game root — they never touch the real repo.

To assert installed content actually loads in the game:

```
Godot_v4.6.3-stable_win64_console.exe --headless --path . res://Tool/verify_content.tscn
```
(edit `Tool/verify_content.gd` to match the items you currently have installed —
it ships checking the sample Frost pack).

## Sample content

The workspace ships with a **Frost pack** demonstrating every type — `chilled`
(stacking speed-down status), `frost_adept` (ranged water pawn that chills on
hit, with generated card art), `winter_sigil` (relic: attackers get chilled, with
generated icon), `frost_nova` (ability: chill all enemies, with generated icon),
`frostbrand` (charm), `winterlore` (2-node upgrade tree), `frozen_patrol`
(undead combat encounter), `eventful_midgame` (event-heavy mid-game node weights).
All verified to load in the game (146/146 regression tests pass with the pack
installed), then uninstalled — install any of them from the tool when wanted.
