# Combat Logic / Presentation Decoupling — Refactor Plan

**Status:** SCOPED, NOT STARTED. Written 2026-07-29 after an alignment session with the user.
**Purpose:** groundwork for the future **board simulation feature** — the enemy engine (and
anything else) simulating full-fidelity hypotheticals by running the REAL rules on a copied
board. Read ENCOUNTER_ENGINE_DESIGN.md decisions 17/17a first for why simulation matters.

---

## ⚡ The governing principle (user's words, do not drift from this)

> **The system should ALLOW us to wait, not FORCE us to do it.**

We are NOT building a parallel "pure rules layer," NOT rewriting resolution into
compute-then-replay, and NOT writing a simulator. The existing cascade logic stays the
single implementation, verbatim wherever possible. What changes is its **dependencies**:

1. **The board becomes a parameter** — the cascade reads the board it was handed, never
   the ambient scene node. The live game hands it the real board; a simulation hands it
   a copy.
2. **Every presentation touch routes through an injected presenter** — awaited animation
   calls AND fire-and-forget sprinkles (`Vfx.play`, `Sfx.play`, tray glints, beat timers).
   The live presenter animates; the null presenter returns immediately.

**Why this works with zero duplicated logic:** GDScript's `await` is pay-per-suspend.
Awaiting a call that completes immediately falls straight through — same stack, same
frame, no yield. One cascade, two presenters: live combat suspends and animates step by
step exactly as today; a simulation runs the identical code synchronously in one call.

**End state:** `SimEffects` (the shadow interpreter) is DELETED. `CandidateApply` copies
the board's cards and runs the real cascade with the null presenter. `can_simulate`
widens from "health/shield only" toward "anything the rules can do" — the refuse-list
shrinks to the genuinely unknowable (random rolls, hidden info; see Open Questions).

---

## Part 1 — Survey: what is already pure (verified 2026-07-29)

The rules CORE needs no work. All of these are `RefCounted`/static, scene-free, await-free
(the regression suite already drives them headless):

| Piece | Fact |
|---|---|
| `Resolver` (resolver.gd, ~600 lines) | static, THE single writer of stats+statuses; zero awaits/VFX/scene refs |
| `EffectSystem` (effect_system.gd) | all-static dispatch/apply; one impurity: `context.board_node.queue_spawn` (:177), see Part 2.4 |
| `TriggerResolver`, `LiveEffects`, `EffectTracker`, `StatusEngine` | pure; LiveEffects is a READ-TIME fold over the unit's own containers — **no global registries exist** |
| `CardInstance`, `StatusInstance`, `CombatSide` | plain `RefCounted` data |
| Event dispatch model | recipients enumerated by SCANNING the board at event time (`combat.gd _broadcast`); nothing is subscribed anywhere |

**Consequence (established in the alignment session):** "the world" = **the board and its
cards** (+ two `CombatSide`s: hands, mana). Copy those, and you have copied the world.
There is no registry soup to untangle — an earlier session-claim to the contrary was
wrong and is retracted.

## Part 2 — Survey: the coupled seams (exhaustive, with line refs)

Line numbers as of branch `enemy-engine` @ 8c2826e + uncommitted work. They will drift;
the function names won't.

### 2.1 The cascade — the heart of the refactor, all in `combat.gd`

These functions ARE the rules of "what happens when an effect fires," and exist only as
methods of the `Combat` Control:

| Function | Logic it owns | Presentation interleaved |
|---|---|---|
| `_broadcast(event)` (:1144) | fan event to origin/destination + every board unit; proc-kill → kill/death/bury re-entry | none directly (awaits `_fire`) |
| `_resolve_event(id, subject)` (:1176) | phase moments: per-holder fan-out, then status DECAY tier, then `cleanup_effect_deaths` | none directly |
| `_fire(event, holder)` (:1053) | per-holder trigger dispatch via `EffectSystem.trigger_grouped` | `await _animator.show_effect_results` per group — "dispatch shows its results BY CONSTRUCTION" |
| `_fire_run_level(event)` (:1066) | relic/upgrade procs for the event | relic-tray glint + `create_timer` beat + animator |
| `_emit_kill(target)` (:~1140) | kill event + **kill bounty payout** (see 2.5) | coin flight VFX via `_pay_bounty` |
| `_bury(inst)` (:776) | corpse removal, king-death branch | `_king_fall` VFX awaited IN FULL, fade timers |
| `_event_ctx(event, holder)` (:1040) | context assembly | pure, but calls `_board.make_context` (scene node) |

The **player cast path** duplicates the shape: `SpellCaster._resolve_on_play` (:106)
awaits `animator.show_effect_results` (:127) between apply steps. The **enemy cast path**:
`combat._cast_enemy_spell` (:535) — `EffectSystem.apply_single` per effect + animator await.

### 2.2 The attack loop (`_run_combat` :619 → `_perform_strike` :672 → `_apply_attack_damage` :950)

Same pattern, heavier presentation (ghost lunge choreography, interception VFX,
dodge/crit beats). **Phase 2 of this refactor** — the simulation feature does not need it
(design 17a: never simulate combat resolution), but the decoupling principle applies to
it identically and it shares `_broadcast`/`_emit_kill`/`_bury`. Decouple the cascade
first, the attack loop after, same presenter seam.

### 2.3 `CombatBoard` (Control) owns logic it shouldn't

- `get_all_units()` (:275), `cleanup_effect_deaths()` (:331) — pure logic over `player_grid`/`enemy_grid` arrays held by a scene node
- **play-event dispatch on placement** (:201, :220, :397): placing a card fires its ON_PLAY triggers from inside the board node
- `make_context(src)` (:76) — the one context builder; injects `ctx.board_node = self`
- `queue_spawn(...)` — spawn payloads queue through the node

### 2.4 `EffectContext` leaks scene types

- `board_node: CombatBoard` (effect_context.gd:25) — consumed by `EffectSystem._run_effect`
  (:177, `queue_spawn`) and by CUSTOM hooks (`effect_hooks.gd:54-71`: reads grids through
  it, calls `refresh()`, `spawn_player_card`)
- `manual_slot: SlotUI` (:24) — a scene Control standing in for what is logically (row, col)

### 2.5 Non-presentation side effects buried in the cascade — ⚠ the subtle trap

`_emit_kill` → `_pay_bounty` (:831) **writes run economy** (gold/exp via
`GameData.kill_bounty`) and flies coins. A simulated kill must do NEITHER. This is not
presenter material — bounty is game logic — it is a **world-scoped policy**: the live
world pays bounties, a hypothetical world doesn't. Same class of concern for anything
else in the cascade that reaches run state (`GameData`) rather than combat state. Sweep
for these during implementation; known list today: kill bounty payout, relic/upgrade
run-level procs writing player resources (mana/draw side-mutations are COMBAT state and
fine — they live on `CombatSide`, which the world owns).

---

## Part 3 — The work, in order

Each step ends green: full suite (`tests/_runner.tscn` — MANDATORY after touching
resolution) + a manual Gym fight to see presentation unchanged.

### Step 1 — `CardInstance.copy()` + world copy (pure data, no behaviour change)

Deep-copy: stat fields, `modifiers`, `charms`, `statuses` (each `StatusInstance`:
`data` ref shared — defs are immutable — but per-instance `remaining/stacks/_trackers`
copied). **Identity remap table** (original→copy), applied to every internal reference:
`StatusInstance.source`, `StatusInstance._carrier_ref`, `killed_by_unit`,
`source_building`. Shared immutables NOT copied: `CardData`, `AbilityData`, `StatusData`.

A `CombatWorld` (name TBD) `RefCounted`: two grids of `CardInstance`, two `CombatSide`s,
`copy()` using the remap. This is the parameter everything below starts taking.
`CombatSide.copy()`: hand/draw_pile through the same remap (hand spells are cast in sims).

Tests: copy independence (mutate copy's stats/statuses/grids — original untouched),
remap completeness (no reference in a copy resolves to an original).

### Step 2 — The presenter seam

`CombatPresenter` (RefCounted) — the complete presentation surface of the cascade,
discovered in Part 2; roughly:
`show_effect_results(results, holder, status_id, cue)`, `play(vfx_event)`,
`sfx(id)`, `relic_glint(id)`, `beat(seconds)` (replaces in-cascade `create_timer`),
`interceptions(list)`, kill/death dressing hooks.
Two implementations: `LivePresenter` (wraps `_animator`/`_vfx`/`Sfx`/tray — bodies moved
verbatim from today's call sites) and `NullPresenter` (every method returns immediately —
which, per the await semantics above, makes the whole cascade synchronous).
Live behaviour byte-identical: same calls, same order, same awaits.

### Step 3 — Cascade re-homing + parameterization (the core step)

Move `_broadcast` / `_resolve_event` / `_fire` / `_fire_run_level` / `_emit_kill` /
`_bury`(logic half) / `_event_ctx` **verbatim** onto a `RefCounted` host (working name:
`CombatCascade`) constructed with `(world, presenter)`. This is relocation, not rewrite —
the minimal move required for a non-scene caller to construct the cascade at all; diffs
should read as mechanical. `combat.gd` keeps one-line delegating wrappers. Board reads
(`_board.get_all_units()`) become world reads; `cleanup_effect_deaths` moves to the world
(it is grid logic); `CombatBoard` keeps a thin forwarding shim + `refresh()` (view-only).
Bounty payout becomes world policy (`world.rewards_live`, false in copies) — see 2.5.

### Step 4 — De-scene `EffectContext`

`board_node: CombatBoard` → the world (spawn queue moves onto it; `effect_hooks.gd`
reads grids/spawns through it; view `refresh()` calls route via presenter or drop —
the live board refreshes on its own signals). `manual_slot: SlotUI` → `(row, col)` ints
(SpellCaster translates at the gesture edge). `CombatBoard.make_context` collapses into
a world method. ON_PLAY dispatch moves out of `CombatBoard.place_*` into the cascade
host, so placement-triggers also run under a chosen (world, presenter).

### Step 5 — Simulation adoption + deletion of the shadow engine

`CandidateApply.apply` for cast/ability: `world.copy()` → real cast path
(`EffectSystem` + cascade) with `NullPresenter` → score the resulting world.
**DELETE `SimEffects`** interpreter body; `can_simulate` inverts from allow-list to a
small deny-list (Open Questions below). `BoardState` decision: keep as the scorer's
cheap read-model, now CAPTURED FROM a world copy (criteria/measurements unchanged), or
retire it later — separate call, not part of this refactor.
The enemy-engine suite (128 checks) must pass with pinned behaviours intact; sim-gate
tests that asserted "statuses are refused" flip into "statuses now simulate" tests.

### Explicit non-goals

- No attack-loop simulation (design 17a stands; the attack loop gets the presenter seam
  in a later phase, not this one).
- No behaviour changes, no tuning, no new criteria. A player must not be able to tell
  the refactor happened.
- No compute-then-replay architecture. Awaits stay in the cascade; they just stop being
  mandatory.

## Part 4 — Acceptance criteria

1. Full regression suite green after EVERY step (755 at time of writing).
2. A Gym fight before/after Step 5 is visually indistinguishable (render-harness spot
   check + live look; MSDF-class issues don't show headless).
3. `EnemyEngine` plans a `fire_bless` ability cast (status application — impossible for
   the old interpreter) once the offensive evals land — the agreed "Bless by Fire" test.
4. Zero direct `Vfx./Sfx./animator` references inside cascade-host code (grep gate).
5. A simulated turn writes nothing to run state (gold/exp/GameData) and leaves the live
   board untouched (test: plan a full CPU turn, assert world hash unchanged).

## Part 5 — Open questions (decide during implementation, with the user)

- **Randomness in simulated effects** (`Effect.chance < 1.0`; future random targets):
  seeded roll per candidate, expectation-scaling, or keep refusing them? (Today: refused.)
  The deny-list of Step 5 is exactly this list.
- **Draw/discard in sims**: `CombatSide` side-mutations (draw, mana) are world-owned and
  simulate fine, but drawing reads a shuffled `draw_pile` — hidden-info policy needed
  (probably: simulate the mutation, don't peek at what was drawn).
- **`BoardState` retire-or-keep** (Step 5). Keeping it is zero-risk; retiring it unifies
  read-models. Decide after Step 5 lands.
- Whether `_resolve_event`'s status-decay tier belongs in simulated casts (it doesn't
  run today in `SimEffects`; with the real cascade it comes along — verify it matches
  live cast semantics, where decay is event-driven, not cast-driven).

## Part 6 — Standing constraints (from memory/repo law)

- Warning-clean GDScript; **no `:=` inferring Variant** (user's editor = warnings are errors).
- Run `tests/_runner.tscn` after ANY resolution-layer change (Arbitration Layer law).
- Commit discipline: per-step commits once the user approves each step, not iteration churn.
- Godot binary: `D:\Godot\Godot_v4.6.3-stable_win64_console.exe` (not on PATH).
- Difficulty found mid-step = a finding to surface, never a silent descope.
