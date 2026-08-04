# Slot Layer — Design & Implementation Guide

Status: **BUILT 2026-08-02 (commits 05edac0 + c73571a + 4268b77, suite 1256 green), not
yet playtested.** The model decisions below were settled in discussion with the user across
several rounds — do not reopen them. §4 now describes what EXISTS; the scope fences in §6
still stand (nothing behind them was built). Burning content (Step 3) remains unstarted.

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

**As built, the ground pass is THREE tiers** (2026-08-03, the spread build):

1. **Procs** — as above, but gathered board-wide and presented as ONE moment
   (`CombatPresenter.show_ground_results(procs)`): mutations land slot by slot in reading
   order, then every acting tab on the board glints AT ONCE as the results land together —
   the whole fire acts as one.
2. **Spread** (`CombatCascade._spread_statuses`) — a status that authors a `spread` block
   (`StatusData.spread`: `{phase, chance, decay_chance, to}`, generic) rolls ONCE PER STACK
   at its phase: `chance` to propagate one stack to the destination `to` names, else
   `decay_chance` for that stack to die down (`StatusEngine.shed_stack`). The jobs are a
   SNAPSHOT taken before any roll: a stack arriving mid-pass never rolls the pass that lit
   it. Rolls draw from the CombatRng `rules` stream. Each roll presents individually and in
   order (`show_spread_roll`): the rolling pip glints identically for every outcome — the
   target's ignition flare is the only success signal (user call). For statuses that author
   spread, the roll IS the lifetime: burning and ablaze are both `decay: "none"` and only
   ever go out by fading here. Universal expiry rule added for this:
   `StatusEngine.is_expired` treats 0 stacks as expired whatever the decay mode.

   **CARRIER-GENERIC** (2026-08-03): the tier runs over slots AND units through one path —
   slots first, then living units, each in reading order. `spread.to` is the destination
   PROVIDER, mirroring the targeting-provider pattern:
   - `"adjacent"` (default) — a random orthogonal neighbouring SLOT on the same half. The
     battle line is a wall; this branch is the one predicate to widen if cross-line
     adjacency ever lands. Meaningless on a unit carrier (units don't ignite each other by
     proximity) — a legal miss.
   - `"ground"` — the slot the carrier STANDS ON. Meaningless on a slot carrier.

   The two are ONE rule seen from each layer: fire moves either sideways within its layer,
   or across the layers at its own address.

   Two more spread fields (2026-08-03, the arrival build):
   - `status` — what the destination CATCHES (default: the roller's own id). A cross-layer
     leap must speak the destination layer's language: ablaze authors `"status": "burning"`
     so a unit's fire lands on the ground as ground-fire. (Without it the slot would catch
     ablaze — a self-targeting unit status the slot dispatch fence rightly refuses; found
     as a live bug when the arrival feature forced the question.)
   - `arrival` — a NAMED EFFECT dealt to whoever STANDS on the caught slot when a stack
     arrives (`CombatCascade._spread_arrival`, manual-targeting through the ordinary
     pipeline — interception/riders/provenance all behave normally). Empty slot = legal
     miss. Burning authors `"arrival": "burn"`: a fire leaping into an occupied cell deals
     its 1 and may ignite, one definition doing both.

   **The rest of the cross-layer bridge is NOT here** — it's `Effect.riders` (see below),
   because what sets a standing unit alight each round is the ground's DAMAGE, not its fire.

3. **Decay**: `StatusEngine.advance(slot, event_id)` — identical call to the unit tier.
   Slots first touched by a spread this pass aren't in the captured `ground` list and skip
   it (a status is never asked to decay the phase it arrived). Subject-scoped events
   (`subject != null`) skip slots entirely (slots are never a subject in this build).

### 4.4b Damage riders — how the ground sets a unit alight

`Effect.riders` (2026-08-03) — follow-ons a damage instance CARRIES onto whoever took it.
Authored on the damage effect: `"riders": [{"chance": 0.3333, "status": {"id": "ablaze"}}]`.
Fired in `EffectSystem._run_riders`, right after the damage mutation lands.

**ONE ROLL PER DAMAGE INSTANCE, flat.** The amount is NOT a multiplier — a 3-damage hit
rolls exactly as often as a 1-damage one. More rolls means more instances of damage, which
is a repetition question living nowhere near this seam (settled with the user 2026-08-03,
who explicitly rejected a per-point variant).

Gated on the damage having LANDED (`delta != 0`): an intercepted-away hit carries nothing,
because the rider rides the damage rather than the attempt. Shield-absorbed damage DOES
carry it — the delta is real, it just spent itself on shield — so a shield is not immunity
to catching fire.

**Deliberately NOT a fire-damage TYPE.** Typed/elemental damage is a separate concern with
no current plans (explicit user call); the rider is a property of the damage an effect
deals, general in the axis that matters — "this damage carries a follow-on". Frost damage
that chills or poison damage that spreads use the identical seam with no new machinery.

**RESTRIKES** (`Effect.per_stack_chance`, 2026-08-03) — "each flame beyond the first may
burn again": when > 0 and the effect fires from a STACKED status container, each stack
PAST THE FIRST repeats the whole effect once, gated by its own roll
(`EffectSystem._restrikes`, both grouped dispatch sites). The first flame burns for sure
(the base activation, unchanged); each repeat is a fresh damage INSTANCE, so riders roll
per repeat — a 10-stack fire is dangerous through repetition, never through bigger
numbers ("heat is flat, stacks are flames" survives). Stackless firings (spells, arrival
touches) ignore it. Results carry `restrike_stack` (1-based index) so presentation glints
EXACTLY the stacks that burned again, and only those (user call): base burn = the
board-wide simultaneous glint, then each restrike re-glints its own tab (ground) or the
badge (unit) with its own number. The burn template authors `per_stack_chance: 0.25`, so
both fires inherit it. ⚠ Tests measuring damage near a stacked burn must calm BOTH riders
and restrike (`test_burning._tick_calm`).

**NAMED EFFECTS** (2026-08-03) — the naming layer over the rider mechanism, the classic
TCG-keyword move. `data/named_effects.json` holds reusable effect PAYLOAD templates;
"burn" (deal 1, 33% ablaze) is the first. A call site authors
`{"trigger": ..., "targets": ..., "named": "burn"}` — it owns WHEN and ON WHOM, the name
supplies WHAT HAPPENS. `Effect.from_dict` merges the template UNDER the authored keys
(authored wins — escape-hatch overrides); `to_dict` returns the authored dict verbatim, so
the reference round-trips byte-faithfully and the expansion never leaks into saved data.
No template chains (NamedEffects refuses a template that names another). Registry is
lazy-loaded (loader static-init order is nobody's contract).

**THE WILDFIRE RULING** (user): ablaze's own tick is ALSO `"named": "burn"` — rider and
all. A burning unit may re-light itself; fire fuels itself by burning things. Tuning knobs,
one place: the chance/amount in named_effects.json, the spread numbers per status.

⚠ **Testing note**: a rider makes any downstream damage sum non-deterministic. Tests that
measure burn arithmetic strip burning's riders for their duration
(`test_burning._burning_riders_off`) and the rider's own behavior is proven separately with
chance-1 / chance-0 statuses.

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
