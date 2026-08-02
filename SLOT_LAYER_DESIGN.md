# Slot Layer — Design & Implementation Guide

Status: **DESIGN LOCKED (user-aligned 2026-08-02), NOT BUILT.** This doc is the authority
for the build; it is written to kick-start implementation on a clean context. The model
decisions below were settled in discussion with the user across several rounds — do not
reopen them; open micro-decisions are explicitly marked. Prerequisite groundwork
(StatusCarrier, §3) is ALREADY BUILT and tested.

Sibling docs: `EFFECT_SYSTEM_DESIGN.md` (effect pipeline), `EVAL_CRITERIA_BRIEF.md`
(enemy engine — explicitly OUT of scope here), `data/statuses/STATUS_AUTHORING_GUIDE.md`.

---

## 1. What this is

Slots become real entities that can carry statuses — the groundwork for "wildfire"
(burning slots that damage and spread) and any future ground-effect mechanic. This build
delivers the MINIMAL version: slots exist, statuses apply to them and tick on them, and a
slot status can target the unit standing at coordinates. Nothing else.

## 2. The settled model (user decisions — the WHY)

**2.1 The board is a stack of LAYERS over one shared coordinate space.**
- Layer "ground": slots. Exactly one per cell, permanent.
- Layer "pieces": units. At most one per cell, transient. This is today's grids.
- Future layers (the user's thought experiment: "atmosphere") must be *cheap to add by
  copying the pattern*, but NO generic layer machinery is built now — design for N,
  build exactly 2.

**2.2 Co-location is incidental — nothing contains anything.** A unit is not "inside" a
slot; it is "on top of" it. Units have coordinates (`CardInstance.row/col/owner` — already
true today); slots have coordinates; the relationship "who stands on me" / "what ground am
I on" is a WORLD LOOKUP at the shared address, derived fresh at read time, never stored.
Consequences, all deliberate:
- The unit grids (`CombatWorld.player_grid/enemy_grid`) are untouched — they remain the
  pieces layer's spatial index and the SINGLE AUTHORITY on occupancy.
- Slots never cache occupants. Ever. (House rule: a widget/entity stores only facts it is
  the authority on.)
- A unit leaving a burning slot leaves the fire behind by construction.

**2.3 Statuses are the actors; carriers are addresses.** Settled during the StatusCarrier
step: a status knows when to tick, trigger, expire (StatusData + StatusEngine own ALL
behavior); a carrier holds a list purely for organization and has ZERO say. Slots are the
second carrier species. Do not put any status logic on the slot.

**2.4 Targeting is position-first, not relationship-first (user ruling).** The primitive
is `AT_LOCATION`: "the unit(s) at these coordinates". It takes a coordinate SET (size one
in this build) and does a relationship-blind layer lookup. WHERE the coordinates come from
is a separate concern — a coordinate PROVIDER. The only provider built now: "this effect's
anchor coordinates" (for a slot status: the slot's own address). AoE/adjacency later =
richer providers feeding the SAME primitive; never a new targeting kind. An earlier
`OCCUPANT` ("the unit standing on me") design was REJECTED for baking the
holder-relationship into the semantics.

**2.5 Bigger frame (context, not scope):** the user sees StatusCarrier as one facet of a
future "game entity core" (identity + position + Resolver-written state bags + read-time
folds). Parked, explicitly: whether statuses and modifiers are even different things. Do
not unify anything here.

## 3. Already built / already true (verify, don't rebuild)

- **`scripts/status_carrier.gd`** (`StatusCarrier extends RefCounted`) — statuses list +
  `find/remove/clear` filing. `CardInstance extends StatusCarrier`. Application rules
  (stacking/clamp/refresh/duration) live in **`StatusEngine.apply(carrier, id, duration,
  stacks, src)`**; `advance`/`triggered_groups` already take `StatusCarrier`.
  `StatusInstance.bind_carrier/copied` already carrier-typed. Suite green (1216).
- **`StatMutation.target` is `Object`** (`stat_mutation.gd:94`) — the Resolver already
  dispatches on target species (`DeckCard` / `CombatSide` / else-CardInstance in
  `Resolver._submit`, resolver.gd:105-120). A slot target is a fourth species with
  precedent, not a contract change.
- **Interceptor degrade falls out free**: `Resolver._intercept` does
  `participant = m.target as CardInstance` (resolver.gd:544) — a BoardSlot casts to null
  → the interceptor evaluation returns early. Unit-shaped interceptors silently don't
  match slot applications. Verify with a test; do not add special-casing.
- **`trigger_global` (`effect_system.gd:68`) is the holderless-dispatch precedent** —
  run-scope effects fire with no holder unit, allegiance anchored via
  `context.owner_anchor`. Slot-status firing follows this pattern.
- **`MANUAL_SLOT` targeting** already carries picked coordinates through the context
  (`EffectContext.manual_row/manual_col`, effect_context.gd:20-24). Slots-as-recipients
  reuse this gesture edge unchanged.
- **`CombatRng.enter/exit_hypothetical`** exists (sims fork RNG) — nothing to build now,
  relevant later for spread rolls.

## 4. The build

### 4.1 `scripts/board_slot.gd` — the entity

```gdscript
class_name BoardSlot
extends StatusCarrier
# One cell of the GROUND layer: a filing cabinet with an address. Coordinates are
# identity; occupancy is NOT stored here (the unit grids are the authority — ask the
# world). See SLOT_LAYER_DESIGN.md.
var side: int = -1    # 0 = player half, 1 = enemy half (which grid's coordinate space)
var row: int = -1
var col: int = -1
```
That is the whole class. No occupant field, no statics, no behavior. `side` is spatial
addressing (which half of the board), NOT allegiance-of-effects — allegiance questions are
answered per-dispatch via `owner_anchor` (§4.4).

### 4.2 `CombatWorld` — the ground layer

- `var slots: Dictionary = {}` — `Vector3i(side, row, col) -> BoardSlot`.
- `func slot_at(side, r, c) -> BoardSlot` — ALWAYS answers; creates + stores on first
  touch (lazy allocation is an invisible detail; slots are permanent once created).
- `func active_slots() -> Array` — slots with a non-empty status list, in deterministic
  reading order (side, then row, then col — sort the keys; dictionaries don't promise
  order). Used by ticking; determinism is non-negotiable (sims re-run these paths).
- **`CombatWorld.copy()`**: deep-copy the layer — new BoardSlot per entry (coordinates
  are stable identity, NO remap needed for slots themselves), statuses via the existing
  `StatusInstance.copied(si, new_slot, remap)` (the remap resolves each status's
  `source` unit ref through the snapshot, same as unit statuses).

### 4.3 Resolver — delivery (single writer preserved)

`Resolver._submit` / `_dispatch_apply`: a `StatMutation.STATUS` whose target is a
`StatusCarrier` that is not a `CardInstance` routes to the same
`StatusEngine.apply(target, ...)` call the unit arm uses (resolver.gd:189). Non-STATUS
mutations aimed at a slot are authoring errors: `push_error` + no-op Outcome (fail loud —
slots have no stats in this build). Everything else (interceptors, LiveEffects
invalidation in `submit`) is already in place or degrades correctly (§3).

### 4.4 Slot statuses tick and fire

In **`CombatCascade.resolve_event`** (combat_cascade.gd:122 — the phase pass that fires
per-unit events then decays statuses), add the ground layer AFTER the unit loops:

1. **Fire**: for each slot in `active_slots()`, `StatusEngine.triggered_groups(slot,
   event_id)` (already carrier-generic); fire matched effects HOLDERLESS on the
   `trigger_global` pattern: `owner_anchor` = slot.side mapped to allegiance (slot on the
   enemy half anchors enemy — micro-decision RESOLVED: the ground inherits the half it
   sits on, until a mechanic needs otherwise), spatial anchor = the slot's coordinates
   (§4.5). Results flow through the normal EffectSystem→Resolver path.
2. **Decay**: `StatusEngine.advance(slot, event_id)` — identical call to the unit tier.
   Subject-scoped events (`subject != null`) skip slots entirely (slots are never a
   subject in this build).

Do NOT build a second dispatch pipeline; this is a caller loop feeding the existing one.
(Presentation note: `trigger_grouped`'s per-container cue/source-proc machinery expects a
CardInstance source — slot dispatch SKIPS cues in this build; see §6 UI fence.)

### 4.5 EffectContext — the anchor coordinates

`EffectContext` gains `anchor_side/anchor_row/anchor_col` (sentinel -1), set ONLY by the
slot dispatch (§4.4). This is the coordinate PROVIDER channel: "where this effect is
anchored, as a location". Unit dispatches don't set it (their anchor is
`context.source`, a unit). Keep it three plain ints — mirrors `manual_row/col`; no
position object, no slot reference in the context.

### 4.6 TargetResolver — `AT_LOCATION`

New resolver class beside `Manual`/`Auto`/`ManualSlot` (`scripts/triggers/
target_resolver.gd`): `class AtLocation extends TargetResolver`. `resolve()` returns the
units found at its coordinate set — this build's ONLY provider: the context's anchor
coordinates (whiff = empty array, legal). Lookup goes through the context's grids
(pieces-layer lookup at an address — reuse the context/world unit-at helpers; add
`CombatWorld.unit_at(side, r, c)` if none exists). Spelling: `"at_location"` in the
targeting-policy string maps (effect.gd ~:463/:639/:694 + the resolver factory,
target_resolver.gd). Conditions still gate targets normally (a slot status CAN say "only
burn non-flying occupants" via target conditions).

### 4.7 Addressing ground from an effect — apply-status-to-slot

Minimal layer-addressing on the STATUS payload: a status-applying effect may declare its
recipient layer, e.g. `"status": {id, duration, stacks, "layer": "ground"}` (default
`"units"` = today's behavior, zero content migration). When `layer == "ground"`,
`EffectSystem._apply` resolves the effect's coordinates (this build: the MANUAL_SLOT
picked cell via `context.manual_row/col`; or the anchor coords if set) and submits
`StatMutation.status_apply(world.slot_at(...), ...)`. Exact payload spelling is the
implementer's call — keep it on the payload (WHAT is delivered), not a new targeting
policy (WHO/WHERE stays the resolver's job).

### 4.8 Authoring rule (fail loud)

A slot-held status's effect conditions may interrogate the TARGET, never a HOLDER unit
(a slot has no composition/stats). Holder-shaped conditions on a slot dispatch =
`push_error` at fire time (authoring bug), not silent never-fire. First data content:
test-fixture statuses only (`_t_`-prefixed, like existing test statuses) — burning is a
LATER, separate step.

## 5. Tests (computation doctrine — see EVAL_CRITERIA_BRIEF.md §Testing)

New `tests/test_slot_layer.gd`, registered in `tests/_runner.gd` (mirror an existing
test's registration). Pin COMPUTATION only, never behavior-quality:
- apply-to-slot: stacking/clamp/refresh via `StatusEngine.apply` on a BoardSlot; Resolver
  path (`StatMutation.status_apply(slot, ...)` through `Resolver.submit`).
- interceptor degrade: a unit-shaped status interceptor does not fire on (and does not
  break) a slot application.
- ticking: slot statuses decay on the cascade's phase events, in reading order;
  subject-scoped events don't tick slots.
- firing + AT_LOCATION: a `_t_` slot status with an `at_location` triggered effect hits
  the unit standing at the slot's coordinates; whiffs legally when empty; hits the NEW
  occupant after a move (incidental co-location — the core model claim).
- copy fidelity: `CombatWorld.copy()` — slot statuses duplicated, stacks/remaining
  independent of the original, status `source` refs remapped, original untouched.
- non-STATUS mutation at a slot: errors, no crash.

## 6. Scope fences (OUT — do not build, do not stub)

- **Relative reach / AoE / adjacency**: only the anchor-coords provider ships. The
  provider vocabulary is the extension point; nothing speculative now.
- **Enemy engine**: NOTHING. No BoardState capture, no scoring, no outcome-comparison
  changes. (Known consequences, accepted for now: the engine cannot see slot state; the
  no-op-veto blind spot for ignite-style casts is documented in EVAL_CRITERIA_BRIEF.md
  §Supporting rules and becomes relevant only when slot-targeting content exists.)
- **Presentation**: no SlotUI pips, no VFX, no source-proc cues for slot containers.
  Pull-rendering comes later; the world state is the truth it will read.
- **Burning / wildfire content**: separate step, after this lands.
- **Slots as event subjects / event-origin widening**: slots never appear in GameEvents
  in this build (holderless dispatch avoids the need).
- **Sim/RNG policy for spread**: parked by the user ("an RNG problem, not a slot status
  problem").

## 7. Practicalities

- Godot not on PATH: `"/d/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless
  --editor --quit --path /d/Godot/CardGame` = parse check (grep `SCRIPT ERROR|Parse
  Error|ERROR:`). ALWAYS pass the absolute `--path`.
- New `class_name` scripts need a headless `--import`/editor pass before the test runner
  sees them.
- Suite: `... --headless --path /d/Godot/CardGame res://tests/_runner.tscn` — must stay
  green (1216 + new); this touches the resolution layer, so the run is MANDATORY.
- Warnings are errors in the user's editor: fully typed GDScript, no `:=` inferring
  Variant, typed `for` loops.
- Edit files with the harness Edit/Write tools only (PowerShell Get/Set-Content corrupts
  encoding).
- Commit discipline: this is a planned phase — one commit when green and approved; no
  look/feel churn commits.
