# Brief: Enemy Evals — the scoring system as decided

This is the authority for the enemy engine's scoring criteria: decisions only, assumptions
labeled. Read it alongside `scripts/enemy/board_scoring.gd` (where everything below
lives). The wider system context is `ENCOUNTER_ENGINE_DESIGN.md`. History, superseded
designs and bug archaeology were pruned 2026-07-31 — git history holds them.

## How the engine works

The enemy engine picks actions greedily, one at a time: it simulates every legal candidate
on a board copy with the REAL rules (`CombatWorld.copy()` + null presenter) and scores the
result through the DECISION TABLE (`BoardScoring.stock()` — judges and peers, below). A
candidate must strictly improve on the do-nothing baseline to be chosen; a candidate a
judge categorically objects to (today: one that leaves the Captain dead) is not an option
at all (`BoardScoring.vetoes`, read in `_pick_best` before the cohort forms).

**The reshuffle candidates** (user-designed 2026-07-31): greedy-one-at-a-time has ONE
compound exception — two-move ARRANGEMENTS (`CandidateMoves.arrangements`), unordered
pairs of movable units × target-column combos, scored as a single destination board and
gated as a whole. They exist because geometry repairs are exactly the plays whose first
step is neutral ("king forward" improves nothing until the opened column is used) — the
must-improve gate kills neutral single steps, so cramped geometry could never be fixed
once built (observed: the whole retinue wedged into the one column behind the captain,
twice). Columns, not slots (every eval is lane-blind — rows would multiply the cohort to
distinguish nothing); a pair must be EXECUTABLE in some order (one move per unit per
turn, a free slot at every step — a swap between two full columns is not a candidate);
deeper reshuffles chain across picks, each accepted pair freeing geometry the next pick
sees. Worst case adds ~500 pair candidates to a pick's cohort; typical boards add far
fewer.

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

### The damage quota (user-designed 2026-08-06 — replaces the sequential pour)

**All threat is melee-targeting pressure — the melee doctrine.** Open mana prices the
unit about to be played, not a spell; spells reaching the back line are out of planning's
control, so the geometry does not price them. The model's ONE JOB is **lane
breakthrough**: how likely the incoming damage is to reach past the screens. Who swings
at whom is unknowable at plan time (targeting policies, dodges, mid-round deaths), so the
model keeps only the knowable parts — the total mass, roughly how many **blows** it
arrives in, and each body's exposure. One closed form (`incoming_allocation`), every line
independent:

- **Blows** (`blow_count`): one per strike of every opposing fielded unit, plus the
  triangular **pretend-units** the player's open mana could still field — costs 1, 2,
  3, … while affordable, a remainder folds into the last pretend unit (3 mana = 2 units
  because 1+2; 6 = 3 because 1+2+3).
- **The blast**: each quantum in turn lands on the most exposed body still STANDING;
  a tie splits the quantum evenly (equal-depth bodies are equally targetable under
  nearest-targeting, so a tie is never a screen). A body is a screen until its pool is
  spent, then the remaining blows walk deeper — **breakthrough is the measured thing**:
  depth = how many blows must be consumed before one reaches you. Bodies the blows never
  reach draw exactly ZERO ("five more-exposed bodies and five blows: the sixth takes
  nothing" — user-corrected 2026-08-06, replacing a same-day exposure-proportional split
  that leaked a dummy-sized share onto a fully screened captain).
- **Landing**: what lands on a body is `min(share × (1 − dodge), remaining pool)`. The
  dodged part is thrown-and-lost (a dodger keeps soaking aim — attention is what a
  screen absorbs); the overkill past the pool is **wasted** — neither is EVER
  redistributed.

By construction: front slots carry strictly more expected damage than back slots; a
covered seat's safety is stepped, not smooth (count of front bodies vs blows); small
bodies annihilate the damage they absorb (the pour's spill-through-the-full-body bug —
a 2-HP fodder passed a queen's overkill onward undiminished, so the eval called a fully
screened captain dead and declined every rescue; observed live 2026-08-06). Harm
semantics unchanged: a body's harm is what it can still absorb, not the mass thrown at
it.

Succession, for the record: proportional spray (no screening, flatten-by-clamp) → the
sequential pour / waterfall 2026-07-31 (screening as subtraction; failed on overkill
conservation — damage is not a fluid, bodies are not sieves) → exposure-proportional
quota (2026-08-06, hours: screening as smooth attenuation; failed the breakthrough
doctrine — everyone eligible drew a share, a fully screened captain read dead) → this
FRONT-FIRST BLAST same day (equal quanta, front-first, waste on kill, tie-split). The
tier and proportional machinery are deleted, not dormant.

**Exposure v2 — RELATIVE depth** (user-designed 2026-07-31, replacing the absolute base):
depth without a screen is not safety. The base term counts distinct own-occupied columns
strictly nearer the front than the slot — zero bodies in front = front line = 1.0
wherever the slot is (the v1 column-index base stamped a lone deep unit 0.25 "safe" while
the waterfall correctly poured everything onto it). Screens are LANE-BLIND
(`COVER_OFF_LANE` = `COVER_SAME_LANE` = 1.0): nearest-targeting resolves by column depth
first, so the v1 same/off-lane 1.0/0.5 split modelled nothing in the rules; the
column-mate 0.25 attention split stays (within a same-depth tie the facing lane is eaten
first — that one IS in the rules). Consequence: the exposure map now agrees with the
split it weights — an unscreened back column reads as the front line it really is.

### The expected-damage model

Persistence's incoming is the damage the fight will actually deal, not raw stat mass —
**stock vs flow**: raw value's attack term prices the asset (a weapon that swings every
remaining round), the persistence channel prices this turn's expected damage; both stay.
The refinements, all inside the measurement vocabulary, invisible to every criterion:

1. **Delivery-discounted threat** (`expected_threat_against`) — each attacker's mass ×
   `delivery` (its own likelihood of living to throw it, from the NAIVE pass — one
   refinement step, seeded raw, cuts the recursion; no fixpoint) × crit expectation. A
   unit that dies before it swings projects almost nothing.
2. **Dodge expectation** — folded into the quota per body, as above.
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

## The decision table (user-designed 2026-07-31 — BUILT; replaces the weighted sum)

**Every number means something you can say out loud; nothing is ever produced by shouting
over a sum.** The scale of a weight is DECISION AUTHORITY on [0,1]: 0 = the concern does
not exist, 1 = the whole decision. There is no "overyes" — the engine clamps. Two kinds
of seat:

- **PEERS** hold a fixed claim: their weight, meaning exactly what it says. A table of
  peers together claims `1 − ∏(1−w)` of the decision (hungers dilute each other —
  attention divides), split proportionally; a lone 0.4 holds exactly 0.4, no share ever
  exceeds its weight, order never matters, equal weights eat equally. The unclaimed
  remainder is indifference and falls to the tie-break.
- **JUDGES** hold full authority and contribute by OBJECTION: a judge's score is how
  strongly it objects to a candidate (0 content, 1 categorical NO), and what it seizes it
  strikes out — candidate total = peer verdict × ∏(1 − objection). Full objection zeroes
  the candidate AND removes it from the pick (`vetoes`): the veto is arithmetic, not an
  engine special case. Judgeship is reserved for win conditions; a judge has NO weight
  dial — its contribution is controlled entirely by its scoring rule.

**The 0..1 score contract:** every seated eval must score on 0..1. An eval that cannot
(unbounded sums, plain counts) is WRONG and is parked — unseated for everyone, personality
opt-in included — pending later inspection. Math: `peer_shares` / `judge_factor`,
pinned by `tests/test_decision_table.gd`.

Within the contract the earlier taxonomy stands: GOALS score a state absolutely;
BEHAVIORS score expression relative to the pick's cohort (`score_pick`, two-pass).

## The stock table

**THE JUDGE — KingSafety** ("Protect the king", 🧠 Enemy AI): objection reads the own
king's stamped endangerment (1 − persistence; the quota reading, never its own
arithmetic) through **THE PANIC WINDOW** — the tank-early → protect-late arc as a stated
rule: below `PANIC_FLOOR` (0.3 expected pool loss this turn) the judge is silent and the
king's fat pool is a fine screen; past `PANIC_CEIL` (0.5) objection saturates at
`GRADED_MAX` (0.95) and protection overrides everything short of the veto; between them
it ramps. "The king tolerates risking a third of its life; by half, nothing else
matters." **Past the death line the objection keeps a GRADIENT** (added 2026-08-06 after
the T3 freeze — every candidate objected 0.95 flat, all rescue moves tied decline, the
king sat on burning ground): the judge reads the UNCLAMPED loss ratio
(`UnitState.loss_ratio`, stamped beside persistence — computed from AIMED pressure, not
landed: the blast caps landed at the pool, which read every overkill as exactly 1.0 and
re-froze the gradient, the T5 freeze; leftover blows with nobody standing aim at whoever
fell last, so total annihilation stays visible) and for ratio > 1 objects
`1 − (1 − GRADED_MAX) ÷ ratio` — 1.05×-lethal strictly outranks 1.9×-lethal, asymptotic
to 1, never categorical short of actual death. The same ratio feeds the SURRENDER
verdict with a margin (`EnemyEngine.SURRENDER_MARGIN` 1.5 — expected loss barely past
the pool is a coin flip under the model's error bars, not doom). Dead king → objection
1, categorical (this IS the old Captain-dead veto, deleted from the engine);
never-staged king → 0; living danger is never categorical (a cornered king picks the
least-bad line). No weight exists to re-tune — the old 2.275 knife-edge is GONE,
dissolved rather than solved; a cowardly or reckless personality would author the
window, not a weight. Floor/ceiling/margin PROVISIONAL, no playtest.

**PEERS:**
- **TotalValue** (1.0, the reference scale) — the stamped `value_total`, min-max
  normalized over the pick's cohort. One number carries fielding, buffing, healing,
  hurting the player, kills and self-preservation.
- **ManaOptimization** (0.6) — scores THE CHOICE: spends nothing → 0; otherwise this
  choice's line ÷ the best line ANY REAL CANDIDATE in this pick offers
  (`mana_capacity_before`, stamped from the cohort — an unplayable card must never
  inflate the denominator). Spending everything and keeping a usable reserve are equally
  1; only WASTE is punished, and waste is only waste when a better line EXISTED. THE
  INVARIANT (pinned): spending mana always scores STRICTLY above spending none — this is
  now also the whole fielding pressure (idle-hand is parked).
- **Formation** (0.1, user-designed 2026-07-31 — the user's ORIGINAL spec, restored
  after three flattened re-expressions each caused a live misplay: "higher value units
  deserve the best seats, better covered slots", nothing added) — pairwise concordance
  between raw (pre-persistence) worth and the v2 EXPOSURE of the seat: a pair is
  concordant when the dearer unit sits at strictly lower exposure; score = concordant ÷
  comparable pairs; equal worth or equal exposure (`FORMATION_EPSILON`) is no
  comparison; none comparable → silent 1.0. "How covered is a seat" is NOT this eval's
  to define — it reads the exposure number the game already computes and every log
  prints. Misordering costs proportionally, never a cliff: a tank fronting the army
  loses only its own pairs ("suboptimal setups still count"). THE PROCESS RULING that
  goes with it: my invented intermediaries (chain links, binary protection tiers, credit
  constants) were UNREQUESTED — each flattened the graded notion and produced the next
  live report (dps fronting a fodder on a coin flip; the one-column stack; the support
  on the fodder's column; the fodder holding the deepest seat over the support at a
  stamped tie). Unrequested additions are removed, not defended. KNOWN SILENCE (on the
  record): intra-stack pairs tie on exposure and drop out — a board that is ONE stack
  and nothing else scores silent; real boards always carry the captain as the outside
  reference, and stacks are judged through their pairs with it. Works WITH the reshuffle
  candidates (above): recovering a tied pair (moving a unit out of a shared column) IS
  the strict improvement the gate accepts. Loudest on a SPARSE board (ratified); a
  tapped unit prices as expendable for one round.
- **Readiness** (0.1) — `1 − forfeited ÷ total activity potential`: a tap's real price is
  the unit's attack AND every OTHER tap-ability it holds (never the ability it bought),
  proportional to the army. Priced with the BoardValueConfig rates.

**Quirks** (opt-in; stock carries the first): **DamageOutput** (0.1) — aggression as
expression over the cohort's best; ratified: "if 1 damage is my maximum, then having 1
mana IS maximizing damage". **BoardValue** — compliant but superseded by TotalValue.

**PARKED — 0..1 contract offenders** (user ruling 2026-07-31): **ProtectionExposure**,
**IdleHand**, **DeathRisk**, **ExpectedHarm**. Unseated for everyone pending inspection;
measures, classes and the survival-weight merge (`merged_survival_weights`) stay whole
and pinned. Consequences accepted: anti-withholding rides the mana invariant alone.
ProtectionExposure's own consequence — quiet-board placement POSITION falling to the
tie-break — is CLOSED as of 2026-07-31 by **Formation**, which is that instinct
re-expressed on 0..1 rather than that criterion unparked; the survival-weight table is
NOT its input (Formation reads raw unit worth), so the merge still awaits a consumer. When one is unparked (re-expressed on 0..1), bring back an
anti-decoration A/B with it (see `_idle_hand_changes_a_decision`).

## Supporting rules

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
distinction). Under the decision table, authored weights live on [0,1] (over-range
clamps — old-paradigm personalities keep working, at the ceiling) and a JUDGE ignores
its authored weight entirely. Shipped starters (`aggressive`, `defensive`,
`board_oriented`) are directions, not balance.

## Open

- **Greedy prefers ONE big body to several small ones** (5 mana: queen alone beats three
  cheap bodies, because each pick compares single actions and min-max mutes board-value's
  raw preference). The documented greedy limitation, now with teeth because value is not
  linear in mana. A proper fix needs lookahead or a per-mana notion of value — a design
  decision, not a tune.
- The player-facing no-op targeting rule ("heals cannot target full-health units",
  keyed off "effect would change nothing") is still pending.
- **Re-expressing the parked offenders on 0..1** (protection, idle_hand, death_risk,
  harm) — each is a design question ("what is this, as a conviction?"), not a rescale;
  none is scheduled, and idle_hand may never return (the mana invariant carries fielding).
- **The Tool UI does not yet render judge/parked seats specially** — the catalog flags
  them (`judge` / `parked`) and the hints say what they mean, but sliders still show.
- **Nothing is playtested.** Every weight, rate and the judge's scoring rule are
  provisional until the user playtests; the suite pins them, but that is
  self-consistency, not validation. Never cite the suite as evidence a value is right.

## Testing doctrine (user ruling 2026-07-31)

**Tests validate that the COMPUTATION happens as specified — never that a BEHAVIOR is
the right one.** Measurements, algebra, plumbing, purity, and dials-reach-the-decision
(direction-free A/Bs) are testable; which move the engine picks on a staged board is
not — behaviors are judged by playtest observation only. Rationale, from experience:
every failed iteration of the system passed the behavior pins, and keeping them green
repeatedly forced staged repricing — they measured the fixtures, not the engine. The
eleven engine-behavior tests were deleted 2026-07-31 (git history holds them); do not
write new ones.

## Standing cautions

- Work in short loops with the user; plain language in summaries.
- Suite runner: `tests/_runner.tscn`; new `class_name` scripts need a headless `--import`
  pass first. Known pre-existing failure mode: test_materials.gd silently truncates on
  the missing "blight_material" ability.
