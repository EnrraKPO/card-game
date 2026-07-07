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
- **✨ from words** (below every effect list): type an effect in plain English
  ("+1 strength to all pawn units") and a local coder LLM (`effectsModel` in Settings,
  default qwen3-coder) writes the JSON. The server teaches it the effect grammar plus
  english⇒json example pairs mined live from the game's own content (via the same
  `describeEffect` that renders "In plain words" — the two directions can't drift),
  validates every attempt and feeds errors back for up to 3 tries. Results land in the
  builder as ordinary editable rows — check the plain-words restatement; if validation
  still objects, the best attempt lands anyway with the error as a toast (the save gate
  keeps final say).

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

**⛶ Advanced mode** — a fullscreen generator (same draft as the compact panel; Collapse
loses nothing) with a **reference browser**: every game card that has art, ranked by
composition affinity against the current card (`POST /api/art/references` — the bare
piece version first, e.g. `bishop_queen` for `darkness_water_bishop_queen`, then pure
subsets by shared components with pieces weighted over elements, then cards with foreign
components). Each entry attaches as **→ img** (single image-model reference, feeding the
img2img / reference-latent paths via `refGameArt`) and/or **+ llm** (up to 4 illustrations
shown to the prompt-writing LLM as style references). The list has a free-text filter
(name / id / composition) and an All / Player / Enemy cards selector; filtering rebuilds
the list in place, and attaching preserves the column's scroll position and filters. Multi-image note: some model
runners (gemma4:31b on current Ollama) crash on multi-image requests — the server then
falls back automatically to per-image style-note calls plus a text-only synthesis call.

Two optional guidance inputs (advanced view; they persist on the item's art draft and
apply from either view's ✨ and 🔎 buttons): **concept direction** — free-text creative
steer, always passed to the LLM — and **how to use the references** — passed only when
reference illustrations are attached (🔎 always passes it: the analyzed image IS the
reference), and carried into the fallback synthesis call too.
Both carry the same named-preset cluster as the shared Style fragment (＋ save preset /
− delete / select; stored globally in settings as `conceptPresets` / `refHintPresets`).

**Item data the LLM sees** (advanced view) lists every summary line the prompt writer
would receive, each with a checkbox — untick lines that pollute the visual concept
(material costs, verbose trigger mechanics). Hidden lines are remembered by their text,
so a line whose content changes reappears visible.

**🔎 match art** (beside ✨) vision-analyzes the item's *current* art (in-game preferred,
else workspace — `POST /api/art/prompt-from-art`) and writes a prompt that would recreate
it: subject, pose, palette, lighting, rendering style. For generating faithful variations
of art you already like — pair it with img2img on the same image. Single-image call, so
it works on runners with the multi-image crash.

**✨ LLM prompts** — the "✨ llm" button beside "↻ auto" asks a local Ollama model
(`POST /api/art/prompt`; URL + model in Settings, default `gemma4:31b` on `:11434`) to
write a rich prompt from the item's FULL data: it reads the same plain-English summary
the editor shows and is instructed to translate mechanics into visual motifs (poison →
dripping venom, heal → radiant glow) while obeying the same hard rules — never
card/frame/stats words, no readable text in the scene, staging matched to the per-type
template it receives as an example. Press again to re-roll; the result lands in the
Prompt field for editing before generation.

Types with no art slot in the game (charms, upgrades, encounters, map nodes) still allow
generation as workspace reference imagery — clearly labeled as such. Statuses DO have a
slot: icons deploy to `assets/ui/status/<id>_status.png` (StatusData's pip-art convention;
pips fall back to glyph + colour without one).

**Art recipe (`tool.art`)** — the art panel's state persists ON the entry when you Save:
prompt, negative, model, dims, steps/guidance, fixed seed, rembg/turbo, the reference
image (source + path/ID), and the ✨ LLM guidance (concept, ref hint, attached LLM refs,
hidden lines). Each generation also stamps `tool.art.last` — the seed, resolved prompt
and style fragment that actually produced the image — so every image is reproducible
from its entry's JSON alone (external scripts can read it straight off the data file).
Opening an entry auto-loads its recipe into the panel; the **↻ Recipe** button re-runs
the last generation exactly (same seed/prompt/style — current model/dims apply, so
change one field for a controlled variation). Game loaders ignore the `tool` key; a
panel you never touch writes no metadata.

**Set generator conflict handling** — before generating, the "⚙ Set…" preview plans every
slot against the live game data **by composition** (elements + pieces, sorted — matching the
game's `composition_key`): genuinely new slots are generated; a composition that already
exists in ANOTHER file (even under a custom id like `frost_adept`) has its definition
**pulled in** — moved verbatim into the family file via `/api/game/move-entry` (Revert on
such an entry puts it back where it came from); compositions already in the family file are
left alone; an id taken by an unrelated composition is skipped with a warning. No more
duplicate-composition twins shadowing each other in the game's registry.

**✨ AI provider** — Settings routes every ✨ feature (art prompts, 🔎 match art, effects
from words) through one provider: **Local (Ollama)** (the default; per-feature models as
above), **Claude Code** (shells out to the installed `claude` CLI in headless print mode —
uses the login/subscription you already have, no API key, no extra billing; model blank =
your Claude Code default), **Claude API** (official SDK; pay-per-token developer platform —
`ant auth login` or `ANTHROPIC_API_KEY`; default `claude-opus-4-8`), or **ChatGPT**
(OpenAI Responses API; pay-per-token; needs `OPENAI_API_KEY`; default `gpt-5.5`).
Non-Ollama providers use their one configured model for all features (the Ollama
art/effects model split doesn't apply) and handle multi-image references natively.

## Tests

```
node Tool/test/api_test.js   # entry-centric API, enabled flag, revert semantics, art deploy
node Tool/test/ui_test.js    # Chrome-driven: create/edit/revert/toggle/generate flows
```
Both run against a throwaway sandbox game root AND an isolated tool workspace — they
never touch the real repo.

`Tool/verify_content.tscn` (edit to taste) asserts specific content loads in-game.
