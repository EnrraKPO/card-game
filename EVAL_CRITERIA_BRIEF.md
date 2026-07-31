# Brief: Enemy Evals — the scoring system as decided

This is the authority for the enemy engine's scoring criteria: decisions only, assumptions
labeled. Read it alongside `scripts/enemy/board_scoring.gd` (where everything below
lives). The wider system context is `ENCOUNTER_ENGINE_DESIGN.md`. History, superseded
designs and bug archaeology were pruned 2026-07-31 — git history holds them.

## How the engine works

The enemy engine picks actions greedily, one at a time: it simulates every legal candidate
on a board copy with the REAL rules (`CombatWorld.copy()` + null presenter) and scores the
result with weighted criteria (`BoardScoring.stock()`). A candidate must strictly improve
on the do-nothing baseline to be chosen, and a candidate that leaves the Captain dead is
categorically vetoed (`enemy_engine._pick_best`).

## The valuation system

**Before ANY value-related eval runs, a whole valuation pass prices every unit on BOTH
sides** (`BoardScoring.run_valuation`, stamped as `unit.value` / `state.value_total`, own
side positive, player side negative). Two stages per unit:

1. **RAW value** — what the unit DOES: attack × strikes (tap-discounted, below),
   abilities, effect categories, speed, arbitrary per-card enhancers (`unit_values`).
   Current health plays no part — a wounded queen is worth the same raw as a fresh one.
   Health/shield rates are MINIMAL (0.1 / 0.2): the pool is the carrier, not the payload —
   its real worth (absorbing damage) is persistence's job, and pricing it in raw value too
   double-counts it. Role tags are NOT consulted (parked; policy, mechanism kept — the key
   parses, accessors answer, `raw_unit_value` never reads it): **roles unfold naturally
   from stats** — a tank IS a big pool around a small kit. Tanks tank by arithmetic;
   protecting high-value targets is a future eval's own job.
2. **PERSISTENCE** — how likely the unit is to still be there after the turn: current
   health + shield vs its expected incoming share (the expected-damage model, below),
   through **ONE tunable dial**: `value = raw × lerp(1, persistence, persistence_weight)`.
   Stock 0.65; below ~0.6 preservation never outbids growth, ~0.8+ the stock king walks
   front unprompted. Tool: 🎛 Tuning ▸ ♟ Board value; per-personality via `value_rates`.

**The stamp is canon**: any eval that needs a worth reads it, never its own arithmetic.
The stamp records WHO priced it (`valued_by`) and re-runs under a different pricer.

Known consequences, deliberate: damage-sharing EMERGES (the king fronts when its fat pool
redistributes incoming off units the fight prices as precious — a price, not a role); a
placement always ADDS value, so anti-withholding holds by construction.

### The expected-damage model

Persistence's incoming is the damage the fight will actually deal, not raw stat mass —
**stock vs flow**: raw value's attack term prices the asset (a weapon that swings every
remaining round), the persistence channel prices this turn's expected damage; both stay.
Three corrections, all inside the measurement vocabulary, invisible to every criterion:

1. **Delivery-discounted threat** (`expected_threat_against`) — each attacker's mass ×
   `delivery` (its own likelihood of living to throw it, from the NAIVE pass — one
   refinement step, seeded raw, cuts the recursion; no fixpoint) × crit expectation. A
   unit that dies before it swings projects almost nothing.
2. **Dodge expectation** — each defender's share of incoming scaled by `1 − dodge_expect`
   (the Resolver's formula on snapshot data; buildings hard 0). The mana part of CPU-side
   threat is never dodgeable.
3. **Crit expectation** — each attacker's mass × `1 + chance × (multiplier − 1)`; also
   folded into `outgoing_mass`.

Approximation boundaries, deliberate: pairwise speed-edge terms are measured against ONE
aggregate reference speed per side (attack-mass-weighted for attackers, exposure-weighted
for defenders — no-pairing doctrine 17b); the interception layer (per-strike relic
rewrites) is invisible; tuning reads live from `Resolver.dodge_tuning`/`crit_tuning` and
the `dodge_enabled`/`crit_enabled` switches are honored — factors exactly neutral in the
harness. `UnitState` captures `dodge_bonus`/`crit_chance_bonus`/`crit_multiplier_bonus`
so relic-built units are priced.

`stat_rates.speed` (flat 0.5) STAYS despite speed also buying dodge/crit/first-strike
through the flows — same stock-vs-flow structure as attack, and the flow corrections are
a few percent. Rejected path, recorded: dropping attack from raw value ("price only
realized damage") would make the CPU myopic — attack's multi-round worth would vanish
into one clamped turn of expected damage.

### The tap-aware attack stock

The valuation is a **this-turn instrument**: `raw_unit_value`'s attack term wears
`TAP_DELIVERY_FACTOR` (0.1) when the unit is exhausted — this turn a tapped sword is
spent; next turn's re-valuation restores it. Without it, buff targeting falls to target
safety and buffs land on sheltered tapped bodies (pinned by
`_buff_prefers_fresh_over_tapped`). Note: position never gates attacking in this ruleset —
every fielded unit swings every round, so buffing a SAFE fresh unit is correct play.

A tap is billed ONCE: the canon price (the discounted sword in TotalValue) is the real
one; readiness is dialed to 0.1 and speaks only for what the valuation cannot see (the
OTHER tap-abilities a tap closes). Fights heavy with non-traceable tap abilities dial it
up per-personality.

## The taxonomy (SETTLED — the load-bearing decision)

Every criterion must be **commensurable**: normalized so its weight purely means "how much
this character cares", never absorbing hidden units of scale. Two kinds:

- **GOALS** — pure measurements of a resulting world-state, normalized against the world.
- **BEHAVIORS** — how fully an action expresses a disposition, normalized as fraction of
  the actor's available expression this pick: raw measure ÷ best raw measure among this
  pick's candidates (actor-not-optimizer). Behavior criteria see the candidate cohort
  (`score_pick`, two-pass), not just one board.

## The stock character (core traits, every personality carries them)

- **TotalValue** (1.0, the reference scale) — the stamped `value_total`, min-max
  normalized over the pick's cohort. One number carries fielding, buffing, healing,
  hurting the player, kills and self-preservation.
- **KingSafety** (2.275) — the win-condition eval: weight × the own king's endangerment
  (1 − persistence off the stamp), negated. A GOAL on 0..1, the simplest criterion in the
  scorer: no tags, no tables, no cohort machinery; THREAT-SCALED by construction (heavy
  threat forces the full retreat, a calm board makes posture free). The Captain-dead veto
  is the absolute half of the statement. Dead-vs-never-staged: a king in the graveyard
  reads −1; a board that never staged one reads 0. Weight is the midpoint of a NARROW
  swept window [2.25, 2.30] — below it the king loses its retreat pick to a fodder taking
  the free back seat; at 2.35+ safety outbids the approved damage-sharing walk. Character
  variation belongs on personalities, not this const. Tool: "Protect the king" in 🧠
  Enemy AI.
- **ProtectionExposure** (0.15) — formation instinct, kept quiet.
- **ManaOptimization** (0.6) — scores THE CHOICE: spends nothing → 0; otherwise this
  choice's line ÷ the best line ANY REAL CANDIDATE in this pick offers
  (`mana_capacity_before`, stamped from the cohort — an unplayable card must never
  inflate the denominator). Spending everything and keeping a usable reserve are equally
  1; only WASTE is punished, and waste is only waste when a better line EXISTED. THE
  INVARIANT (pinned): spending mana always scores STRICTLY above spending none. Known
  deviation from the literal spec, flagged not hidden: "spend 1, strand the rest" scores
  `cost ÷ capacity`, not 0 — ordering unaffected, and a literal 0 ties declining, which
  the strict-improvement rule cannot tolerate.
- **Readiness** (0.1) — `1 − forfeited ÷ total activity potential`: a tap's real price is
  the unit's attack AND every OTHER tap-ability it holds (never the ability it bought),
  proportional to the army. Priced with the BoardValueConfig rates.
- **IdleHand** (1.0) — every placeable unit in hand the CPU could field right now, one
  full weight each; a plain COUNT, never diluted. Three gates matching
  `CandidateMoves.placements`: placeable unit, affordable, empty own slot. Affordability
  is judged against `hand_budget_before` — the pool as the PICK began, never the mana
  left (else any spend excuses the withholding). **The waiver**: a choice that spends
  mana is never charged — the target is idleness, not the preference between two paid
  plays; the greedy loop re-asks after each action, so the body still goes down.
  `_idle_hand_changes_a_decision` is the anti-decoration pin (it also mutes
  `king_safety`: a fielded body is king cover).

**Quirks** (opt-in; stock carries only the first): **DamageOutput** (0.1) — aggression as
expression, `attack × strikes × delivery` (persistence + first-strike insurance +
tap cap) over the cohort's best; ratified: "if 1 damage is my maximum, then having 1 mana
IS maximizing damage". Plus the **PARKED trio** — DeathRisk, ExpectedHarm, BoardValue —
out of the stock character whole, for any personality that wants the old readings back.

## Supporting rules

- **No-op plays are vetoed engine-side**: `EnemyEngine._effect_changed_nothing` rejects
  any cast/ability whose resulting state matches the current one on OUTCOMES, ignoring
  the play's own costs. Known limit: a pure-marker status folding into no captured stat
  would be wrongly vetoed. The PLAYER-facing targeting rule ("heals cannot target
  full-health units", keyed off "effect would change nothing") is still pending.
- **Engine-stamped BoardState fields must be forwarded in three places** —
  `BoardState.copy()`, `CandidateApply._capture_back` (it REBUILDS the state
  field-by-field), and the engine's stamping — or a criterion goes quiet on casts only.
  Warning comment at the seam.

## Authoring model — personalities

Weights are authored as **named characters**: `EnemyPersonality`
(`data/enemy_personalities.json`, Tool ▸ 🧠 Enemy AI), named by an encounter template's
`personality` key. Core-vs-quirk is a TOOL distinction, not an engine one; an uncarried
quirk is not constructed at all (identical arithmetic to weight 0, honest criterion
dumps). The consts in `board_scoring.gd` are DEFAULTS a personality inherits; survival
weights are part of the personality, with the encounter's table layering on top. No
personality = the old engine exactly (pinned, including the absent-vs-empty `quirks`
distinction). Shipped starters (`aggressive`, `defensive`, `board_oriented`) are
directions, not balance.

## Open

- **Greedy prefers ONE big body to several small ones** (5 mana: queen alone beats three
  cheap bodies, because each pick compares single actions and min-max mutes board-value's
  raw preference). The documented greedy limitation, now with teeth because value is not
  linear in mana. A proper fix needs lookahead or a per-mana notion of value — a design
  decision, not a tune.
- The player-facing no-op targeting rule (above).
- **Nothing is playtested.** Every weight and rate is provisional until the user
  playtests; the suite pins them, but that is self-consistency, not validation. Never
  cite the suite as evidence a weight is right.

## Standing cautions

- Work in short loops with the user; plain language in summaries.
- Suite runner: `tests/_runner.tscn`; new `class_name` scripts need a headless `--import`
  pass first. Known pre-existing failure mode: test_materials.gd silently truncates on
  the missing "blight_material" ability.
