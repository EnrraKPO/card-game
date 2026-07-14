# Cue Population Initiative — Brief

**For a fresh context picking this up: read this whole file, then `memory` entries
[sfx-pipeline], [vfx-library], [feedback-descoping-by-footnote] before writing any code.**

## Purpose (the acceptance test for everything)

The game must be **fully populated with SFX and VFX at every relevant existing cue**, via cheap
placeholder looks/sounds that are **easy to replace and churn on**. The libraries are a
**production task list**: the user picks any enabled entry, observes its placeholder firing in
game, judges it, generates the real asset from the entry's prompt, drops it in — live
immediately. Invariant: **enabled library entry ⟺ observable in-game cue serving a concrete
purpose.** No speculative enabled entries; no known cue without an entry. Anything that improves
communication / makes the game look finished is in scope.

Done = the user can playtest and every relevant moment speaks/shows, and the coverage audit
(below) has zero gaps. The user's playtest is the final gate — code-path verification and
render snapshots are the machine ceiling (we cannot hear).

## Current state (all committed on main, local — push blocked on user git auth)

- SFX pipeline (fdde46c): `data/sounds/sounds.json` (102 entries: concept + AI prompt each),
  `SoundData` registry, `Sfx.play(id)` + loop lanes + per-id synth placeholder. ~10 moments wired.
- VFX pipeline (2c40c11, d9769df, 12aa012): `data/vfx/vfx.json` (167 entries incl. 27-element
  variant sets — 6 singles + 21 king-named duals, ids = sorted composition e.g.
  `projectile_air_fire`), `VFXData` registry, `Vfx` autoload — `play(id, target: Control, opts)` /
  `attach/detach` sustained lane, 13 procedural behaviors, renderer-indirection seam
  (`renderer: "procedural"` today). 5 moments wired (hand draw, mana refill, victory/defeat,
  map node select, shop buy).
- `DevFlags` autoload: F7 mutes placeholder SFX, F8 placeholder VFX (persisted user://dev_flags.json).
- Tool: 🔊 Sounds + 🎇 VFX tabs, validation, in-browser previews.
- Known bug fixed: halo alpha product (base color alpha 0 × modulate = invisible) — pattern to
  avoid in any new behavior.

## The architectural decision (locked in discussion — do NOT re-litigate)

Duplication exists: `VFXPlayer`'s 12 bespoke effect classes, `Vfx`'s 13 behaviors, and
`GlossyButton.set_glow` are three renderers of one visual vocabulary, with two dispatch
registries and two event vocabularies. The user explicitly flagged this class of special-casing
as expensive debt. The cut:

- **Choreography stays combat code** (`VFXPlayer.play_results` sequencing: source glint first,
  reticles lead, simultaneous multi-target bursts, interception order, damage deferral to
  projectile arrival). Sequencing ≠ rendering.
- **Every LOOK resolves through the library**: `VFXPlayer` loses `_make_effect`; the 12 designed
  classes are registered on their library entries as a **custom renderer kind** (no rewrite, zero
  visual change, one dispatch). Same seam later takes flipbook/asset renderers.
- **Element resolution**: choreography asks for (kind, composition) → library resolves
  `projectile_<sorted_comp>` → falls back to the base designed look. Applies to combat
  projectiles/impacts and Forge/Lab combines. This is what makes the 81 elemental entries live.
- **`GlossyButton.set_glow` migrates** to `Vfx.attach("ui_button_attention", …)`.
- **Companion SFX field**: VFX entries get optional `sfx: "<sound_id>"` played atomically by
  `Vfx.play` — cue pairing lives in data, not duplicated at call sites. (User approval read from
  the "OK" that greenlit this scoping; **confirm with one line at kickoff before building it.**)
- Speculative entries (no system behind the moment, e.g. level_up_radiance, screen transitions
  if unbuilt): park `enabled: false` — visible backlog, never deleted (user's standing
  scope-reversal rule). Tool should visually separate parked entries.

## Deliverables (branch `cue-population`; one commit per deliverable, in order)

Each deliverable must leave the game shippable: compile clean, suite `tests/_runner.tscn`
349/349, and its own verification evidence. Commit before starting the next. This ordering
exists so progress survives context exhaustion.

- **D1 — Unified dispatch.** Custom-renderer registration for the 12 combat classes;
  `VFXPlayer` routes all looks via `Vfx.play`; delete its registry; pixel-verify combat renders
  before/after (SubViewport snapshot technique — see [vfx-library] memory: windowed run, service
  instanced INSIDE the SubViewport for local shots; the autoload draws on the root viewport).
- **D2 — Element resolution.** (kind, composition) → variant id → fallback. Wire at combat
  projectile/impact sites and Forge + Lab combine sites. Verify: a fire unit's triggered damage
  visibly flies `projectile_fire_*`.
- **D3 — Companion `sfx` field** (after kickoff confirmation): schema + `Vfx.play` firing it +
  Tool field/validation. Small.
- **D4 — Combat population.** SFX companions for every choreographed moment (via D3 bindings on
  the VFX entries where possible; direct `Sfx.play` where a moment is sound-only) + remaining
  combat VFX cues (king hit/critical, ability flare, autocast arm, spell fizzle, summon, move…).
  Burst gating judgment: per-burst not per-target where barrages occur; volume trims in data.
  Most delicate step — respect await chains; do not double-VFX choreographed moments.
- **D5 — Non-combat population.** Hand select/deselect/discard; map travel/arrival/stage/rest/
  events; shop/rewards/relics; lab tokens/refine/forge; decks; upgrades; charms; embark/run-end;
  app-wide UI (denied, tabs, modals, errors) — incl. ONE hook in `Nav.goto` for screen open/close
  cues everywhere. Migrate `set_glow` here too.
- **D6 — Reconciliation + audit.** Sweep both libraries against reality: park speculative
  entries, add entries for any discovered uncovered cue, produce `CUE_COVERAGE.md` — every
  enabled entry ↔ call site `file:line` ↔ triggering player action. That table is the production
  task list. Update memory entries. Invariant holds or the pass isn't done.

## Cautions (earned the hard way — see memories)

- Godot headless: ALWAYS absolute `--path /d/Godot/CardGame`; wrong cwd = silent project-manager
  idle that looks like a hang. Headless renders no textures — pixel checks need a windowed run.
- Warnings are errors in the user's editor: no `:=` inferring Variant.
- The user's purpose is the completion test. Do not descope silently; do not report "done" with
  gaps in a footnote. If a step must shrink, ask FIRST.
- Combat regression suite after ANY resolution-layer-adjacent change.
