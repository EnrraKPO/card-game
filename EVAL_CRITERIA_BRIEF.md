# Brief: New Enemy Evals — Damage Output & Enemy Value

**Written 2026-07-29 as a handoff into a clean session.** This is the design-complete,
build-pending record of the offensive-criteria initiative. Everything here was settled in a
design conversation with the user; items marked OPEN were explicitly left undecided. Read
this alongside `scripts/enemy/board_scoring.gd` (the file all of this lands in). The wider
system context is `ENCOUNTER_ENGINE_DESIGN.md` — but note the user considers that doc
cluttered; treat THIS file as the authority for the criteria below, and keep this file in
its style: decisions only, assumptions labeled.

## Where the engine is today

The enemy engine picks actions by simulating every legal candidate on a board copy and
scoring the result with weighted criteria (`BoardScoring.stock()`). All current criteria
are defensive/procedural: `DeathRisk` (dominant), `ExpectedHarm`, `ProtectionExposure`,
`BoardPresence`. Nothing rewards hurting the player — damage spells are only ever played
for their side effect of reducing threat against the CPU. Simulations run the REAL rules
(combat decoupling complete: `CombatWorld.copy()` + null presenter), so offensive criteria
can trust what a cast actually does.

## The taxonomy (SETTLED — the load-bearing decision)

Every criterion must be **commensurable**: normalized so its weight purely means "how much
this character cares", never absorbing hidden units of scale. Raw incommensurable sums are
rejected. Two kinds of criteria exist:

- **GOALS** — pure measurements of a resulting world-state, normalized against the world.
  All existing criteria are goals; their currency is *fractions of a unit's life, times how
  much that unit matters* (see `urgency`, `ExpectedHarm`).
- **BEHAVIORS** — measurements of how fully an action expresses a disposition, normalized
  as **fraction of the actor's available expression this pick**: raw measure of the chosen
  candidate ÷ best raw measure among this pick's candidates. Behaviors are about the
  choosing, not outcomes (actor-not-optimizer). This requires a two-pass score within a
  pick (measure all candidates raw, then normalize by the cohort max) — cheap, because the
  engine already simulates every candidate; the denominator is a `max()` over numbers
  already computed. It IS a contract change: behavior criteria see the candidate cohort,
  not just one board.

## The three new evals

### 1. "Reduce enemy value" — a GOAL (build first; nearly free)
Value-weighted **linear harm** to player units: damage as a fraction of the target's health
pool (full → 0; overkill wasted; kills NOT special — this is deliberately NOT
death-probability, which the user rejected as kill-oriented) × target value × criterion
weight. Because a nearly-dead unit offers little remaining scoreable pool, and static
scoring never knows exactly where damage lands, this naturally spreads damage rather than
tunnel on kills — the user predicted and wants this.
- **Structure:** the mirror of `ExpectedHarm` — same math pointed at PLAYER units,
  sign-flipped, with a **value table** instead of survival weights.
- **Target value default = mana cost.** Override resolution reuses the existing pattern:
  card-id > captain > role > default, per-encounter override in the template JSON exactly
  like `survival_weights`.

### 2. "Maximize damage output" — a BEHAVIOR — **BUILT 2026-07-29 (out of order, user's call)**
Aggression as expression: raw damage measure of the candidate ÷ max raw measure available
among this pick's candidates. Independent of target value; a character trait, not a plan.
- **As built:** `board_scoring.gd` — `outgoing_mass`/`delivery`/`first_strike_share`
  measurement functions, `Behavior` criterion subclass + `DamageOutput`, `score_pick`
  cohort contract (do-nothing baseline is cohort entry 0); `enemy_engine._pick_best` is
  two-pass. Stock weight `DAMAGE_CRITERION_WEIGHT = 0.1` — 0.25 made the support cast
  fire_bless while its 1 HP dps died; triage must beat aggression in stock. Per-encounter
  criterion-weight authoring NOT built yet (goes with the authoring-model step). Suite
  852/852 incl. `_engine_casts_damage_buff` (buffs now get cast — the stated goal).
- **TAPPING PRICED (user playtest feedback, 2026-07-29):** a tapped unit swings nothing
  this round, so `delivery` hard-caps exhausted units (`TAP_DELIVERY_FACTOR = 0.1` — a
  sliver survives because the stat persists into future turns). Consequences, both pinned
  by tests: tapped units are near-dead buff targets, and a tap-ability's cast pays the
  holder's own spent swing inside the candidate's score — "is this worth my tap" is part
  of every ability evaluation. The support now blesses a fresh striker, never itself.
- **RATIFIED 2026-07-29:** the tiny-best-option consequence is correct — "if 1 damage is my
  maximum, then having 1 mana IS maximizing damage." Full expression weight stands. Scaling
  the weight by absolute damage TOTAL may be valuable but is OUT OF SCOPE for now.
- **THE REAL GOAL (user, 2026-07-29): get damage BUFFS used.** Today nothing in the scorer
  reads the CPU side's own attack stats (`threat_mass` sums the PLAYER's attack × strikes
  only), so buffing own attack changes no criterion and the must-improve rule discards it.
  Sims resolve the candidate itself with real rules but never the strike phase — so attack
  damage is measurable ONLY as stats (a projection), while spell/ability damage is
  measurable as actual health drops. Division of labor: spells are rewarded by eval 1;
  buffs, placements and attack-raising abilities by THIS eval. No double-counting.
- **THE MEASURE (SETTLED 2026-07-29): durability-weighted outgoing damage mass** of the
  resulting state — attack stats alone are not enough; +10 attack on a unit that dies
  before swinging is nearly worthless. Per CPU unit:
  `attack × strikes × delivery`, where `delivery` folds in survivability and speed:
  - persistence = `1 − urgency(state, unit)` — reuses the existing measurement verbatim,
    so health, shield, screening cover and the actual threat facing the unit all count;
  - speed = first-strike insurance: a unit's first round of damage is delivered before it
    can die if it acts before the threats aimed at it — `delivery = first_strike_share +
    (1 − first_strike_share) × persistence`, with first_strike_share = the fraction of
    player threat SLOWER than this unit (static stat comparison, never resolving fights).
  All of this lives inside ONE measurement function (the CPU-side mirror of `threat_mass`),
  invisible to the criterion — refine the math later without touching anything else. User
  explicitly wants "something that gets us going", not perfection; constants provisional.
- **Normalization confirmed:** cohort-relative — candidate's measure ÷ best measure among
  this pick's candidates; 1.0 = "the most aggressive expression available right now",
  never a global ideal. Weight then purely means "how much this Captain cares".

### 2b. "Total board value" — **DESIGNED + BUILT 2026-07-29 (user-designed in session)**
The net worth of the battlefield in one currency: every unit priced by its full kit —
stats at authored exchange rates + fixed stat-equivalences for abilities / triggered
effects / live effects — own units positive, PLAYER units negative. Normalization
(user-settled): min-max over the pick's cohort — worst option 0, best 1.
- **Exchange rates (user's biases, ALL tool-authorable per user mandate):** attack 1:1 on
  attack × strikes; current health 1:1; missing health (max − current) at 1:2 — heal
  potential retains half value; shield 2:1 positive (regenerates); speed 1:2 negative.
  Abilities default 2.0 with per-id overrides; triggered effects 1.5; live effects 1.5.
- **REPLACED BoardPresence (user call):** same fielding-pole job, real currency instead of
  mana cost; presence's linearity property deliberately lost. Also makes eval 1 ("reduce
  enemy value") REDUNDANT for now (user: a more specific eval may still come later) —
  negative player-side value already rewards damage spells and kills.
- **As built:** `BoardValueConfig` (data/board_value.json, EconomyConfig load pattern) +
  `unit_value`/`board_value` in board_scoring.gd + `BoardValue` behavior (Behavior grew a
  `normalized(raws)` hook: default ratio-to-max, BoardValue overrides min-max for signed
  measures). UnitState captures triggered/live effect COUNTS (ON_PLAY excluded — already
  fired; status-borne excluded). Weight 0.05 (see const comment: growth stays quieter
  than triage; at 0.1 knife-edge preservation picks reorder). Tool: 🎛 Tuning ▸ ♟ Board
  value section + /api/board-value (server sanitize mirror). Suite 860/860.
- **Character shift the build surfaced (re-pinned deliberately):** on the staged
  wounded-ally board the engine now RETREATS the dying dps (free move), then spends the
  tap on fire_bless — instead of healing in place. Verified coherent via criterion dump:
  heal still beats bless head-to-head; the free retreat simply answers the danger first.
  Heal-wins-when-immobile stays pinned by the place-vs-heal test (rooted building).
  `_engine_heals_wounded_ally` → `_engine_preserves_wounded_ally`. USER HAS NOT SEEN THIS
  YET — surface it.

### 3. "Mana optimization" — **REDESIGNED + BUILT 2026-07-29 (user-designed, absorbs
"spend all mana")**
The stranded-only version below proved insufficient: doing nothing always maxed it (every
option still open), so it could never push the engine to ACT — and the board-value swap
had exposed exactly that hole (live withholding bug: normalized value's edge is capped at
its weight and lost to a placed unit's own risk share, so units stayed in hand). The
user's refinement adds the missing ingredient: **spent outranks spendable**.
- **RESHAPED 2026-07-30 (user): the measure scores the CHOICE, not the turn's running
  total.** The earlier cumulative form (`spent + discount × spendable ÷ total`) was a
  misreading; the user's rule is: *any choice that spends ≥1 mana and leaves the
  remainder fully usable scores 1 — equally.* Spending everything and keeping a usable
  reserve are equally fine; only WASTE is punished. Formula:
  - spends nothing → **0** — the spec's "spends at least 1 mana" condition, encoded as the
    function's FIRST gate rather than left to fall out of a formula (it kept not falling
    out; see the invariant note below);
  - otherwise → **what this choice's line consumes ÷ the best line ANY REAL CANDIDATE in
    this pick offers** (`mana_capacity_before`, stamped by the engine from the cohort).
    "This choice's line" = its own cost + the largest subset-sum of remaining option costs
    that still fits.
- **The yardstick comes from the CANDIDATE COHORT, which is what makes the pressure
  structural.** Because the denominator is the best line any candidate actually offers,
  the best available play scores EXACTLY 1.0 and declining scores EXACTLY 0.0 — so the
  incentive to play is always the criterion's full weight, never an epsilon a risk term
  can swallow. Deriving it from the hand instead (subset-sum over `hand_costs`) was the
  bug's fourth disguise: an unplayable card (unsimulatable, or no legal target) inflated
  the denominator beyond any candidate's reach, so every play scored below 1 and the
  margin over declining collapsed. Pinned by `_mana_pressure_is_structural`, which
  includes an unplayable-spell fixture.
- **The counterfactual denominator is load-bearing: waste is only waste when a better
  line EXISTED.** Every anchor the user gave falls out of that one ratio, no special
  cases: spend the whole pool → 1; spend some with the remainder still fully usable → 1
  (equal, only waste punished); mana beyond what all options could ever cost → 1
  (abundance); squander a big spend on a small one (5 mana, options 1 and 5, take the 1)
  → 0.2; combo blindness cured (5 mana, options 2/3/4 → the 4 strands a point and scores
  below the 3 or the 2). Two earlier shapes are superseded: a `MANA_SPEND_FLOOR` patch
  and an absolute "abundance" clause, both of which this subsumes.
- **Known deviation from the literal spec, flagged not hidden:** the user's "use 1 mana and
  leave the rest of the pool unusable → minimum of 0" scores `cost ÷ capacity` (e.g. 0.2),
  not exactly 0. Ordering is unaffected — it is still the bottom of the spending range —
  and making it literally 0 is what caused the second withholding bug, since declining is
  also 0 and the engine needs STRICT improvement to act.
- **⚠ THE 2026-07-30 WITHHOLDING BUG (user report: "plays a single fodder, never a dps")
  was caused by judging leftover mana ABSOLUTELY.** A real enemy hand holds cards the CPU
  cannot yet afford; with one lingering, the leftover always read as stranded, so the last
  affordable play scored no better than declining and the unit stayed in hand. The staged
  test passed only because its hand was fully affordable. Pinned now by a fixture with an
  unaffordable card in hand — keep it.
- **Weight `MANA_CRITERION_WEIGHT = 0.6`** — the per-pick swing is now the FULL 0→1 (not a
  thin fraction), so the old 3.5 would have bulldozed every other criterion. 0.6 outbids
  a placed body's own risk share on the staged repro while staying under genuinely
  precious lives, so a play that throws something valuable away can still be declined.
- **Plumbing:** the engine stamps the mana story onto BoardState (`enemy_mana_total/left`,
  `hand_costs`, plus `mana_spent_step` = what THIS choice spent; `_pick_best` zeroes the
  baseline's each pick, `_note_spend` stamps each candidate's).
- **Side effect, deliberate:** paid plays now outrank free moves within a pick (spending
  scores, repositioning doesn't) — this restored the ORIGINAL wounded-ally character
  (support heals its dying dps; the brief's earlier retreat-then-bless note is obsolete).

### The original "spend all mana" sketch (superseded by the above)
Measured on the post-candidate state, not on mana spent: **stranded ÷ total turn mana**,
where stranded = remaining mana that NO subset of remaining playable option costs can
consume (subset-sum over tiny numbers). With 5 mana and options costing 2/3/4, playing the
4 strands 1 → scored worse than 2 or 3. Bonus: this cures greedy's combo blindness for
spending without any sequence search.
- Spendability counts playable options **loosely** (any legal play counts; don't try to
  judge usefulness). Escalate later only if it misbehaves.

### 3b. "Readiness" — the tap counterweight — **DESIGNED + BUILT 2026-07-30 (user)**
The mana eval sees only mana leaving the pool, so it would tap every unit holding an
affordable ability. But an ability's real price is never just its mana: a tap spends the
unit's **attack for the round and every other ability it holds**. Readiness prices that
second currency so declining a tap stays a live option (user: discourage tapping, do not
prevent it).
- **The measure (a GOAL, 0..1):** `1 − forfeited ÷ total activity potential` over own
  units, where a unit's *activity potential* = attack × strikes + the value of every
  tap-gated ability (non-tap abilities and passives excluded — a tap does not close
  them), priced with the existing BoardValueConfig rates so it stays tool-authorable.
- **A tap is never billed for the ability it BOUGHT** — exactly the user's model
  ("negates all OTHER abilities... and also the attack"). `tap_forfeit = potential −
  best tap-ability`: a one-ability unit that taps forfeits only its swing; silencing a
  deep toolkit costs the whole rest of it. (First implementation over-charged by counting
  the used ability as lost; corrected before landing.)
- **Proportional to the army:** tapping your only unit spends all your agency; tapping
  one of eight spends an eighth.
- **Scoring the STATE is enough to price the CHOICE** — must-improve compares each
  candidate against the do-nothing baseline, so the drop between them IS the tap's cost.
  No cohort machinery, no prev/next plumbing.
- **Weight `READINESS_CRITERION_WEIGHT = 0.4`**, deliberately under mana's 0.6:
  reluctance, not refusal. Measured on staged boards, a tap now costs ~0.2–0.33 against
  mana's 0.6 gain — worthwhile taps still happen (the buff/heal acceptance tests hold),
  and self-buffing (which taps the buffed unit) now scores clearly below buffing an ally,
  which was the user's original complaint.

### 4. "Idle hand" — the blunt instrument — **DESIGNED + BUILT 2026-07-30 (user's call)**
The user's instruction, verbatim in intent: *stop inferring withholding from the mana pool
— forbid it.* Every placeable unit in hand that the CPU could field right now is charged
the criterion's FULL weight. A GOAL, measured on the resulting state.
- **Why a fourth criterion instead of another mana fix:** the mana eval had been rewritten
  three times chasing the same bug, always by reasoning about leftover mana, and the user
  reported it again. This one never looks at the pool's leftovers — it reads the withheld
  cards. If a body could stand on the board and doesn't, that is the charge.
- **The measure (`BoardScoring.idle_hand`)** — a plain COUNT, not a fraction: withholding
  two bodies is twice the offence, and the whole point is that the charge is never diluted.
  Same shape as DeathRisk, which is also a plain sum over units. Three gates on "could
  play", matching `CandidateMoves.placements` exactly so a charged card always has a real
  candidate: it is a placeable unit (spells and kings never enter the count); it is
  affordable; there is an empty own slot.
- **Affordability is judged against `hand_budget_before` — the pool as it stood when the
  PICK began, never the mana left.** This is the load-bearing detail and the first bug the
  build hit: read against the mana left, ANY spend makes the held body unaffordable and the
  charge evaporates, so casting a spell would "excuse" keeping a unit in hand — the
  withholding bug in a new costume. Judged counterfactually, only actually FIELDING the
  body pays the charge off. Pinned by `_idle_hand_shape`.
- **THE WAIVER (user correction, same day): a choice that SPENDS MANA is never charged.**
  The first cut charged every candidate that left the hand untouched, which meant it was
  really punishing ABILITY USE — a heal costs a tap and a mana but empties no hand, so it
  carried the full charge and lost to fielding a body, and the engine stopped rescuing
  dying units. What the user is forbidding is IDLENESS while holding a playable unit, not
  the preference between two paid plays. So the charge now falls only on choices that spend
  nothing: declining, and free repositioning. One gate, `mana_spent_step > 0` — the same
  per-choice stamp the mana criterion reads.
  - The fielding pressure survives because the greedy loop asks once per action: a turn
    that spends its mana on a heal returns to a pick where the body is still in hand, and
    there the placement competes against declining, which IS charged. The unit still goes
    down, just not necessarily before the heal.
  - Consequence worth knowing: the criterion no longer argues "field the body" over "spend
    the mana on something else" — that arbitration is board value / damage output / death
    risk again, as it was. It argues only against spending nothing.
- **Weight `IDLE_HAND_CRITERION_WEIGHT = 1.0`** — one idle body costs more than any
  non-captain survival weight (dps 0.3, support 0.5) and more than mana's whole swing
  (0.6): with a body in hand, a turn that spends nothing has to be worth more than a
  certain death. Dial documented in place: 0.0 = off, 0.5 = a valuable free move can still
  win a pick, 1.0 = current.
- **Every previously approved behaviour is intact** — the place-vs-heal arbitration is back
  exactly as it was (the heal spends mana, so the charge never enters that argument), and
  it is the test to watch whenever this rule is touched.
- **`_idle_hand_changes_a_decision` is the anti-decoration pin:** the same pick scored twice
  (criterion on / weight zeroed) on two knife-edge boards found by sweeping the held body's
  survival weight — at 2.0 the charge is exactly what tips a reluctant placement into
  happening; at 4.0 the body is such a pure loss that even the full charge cannot buy it,
  which is the must-improve restraint still working. If those two scorings ever agree, the
  criterion has stopped doing anything.
- **Landmine closed on the way (`CandidateApply._capture_back`):** the cast/ability path
  REBUILDS the BoardState from the simulated world field-by-field instead of copying it, so
  the two new fields silently read as zero on casts only — the criterion looked correct on
  placements and went quiet on heals, i.e. the criterion was decoration for its first
  iteration. Every engine-stamped BoardState field must be forwarded in three places:
  `BoardState.copy()`, `_capture_back`, and the engine's stamping. Warning comment added
  at the seam.
- **Not yet playtested.** Suite 930/930, which per the standing caution is self-consistency,
  not validation.

## Supporting rule change (SETTLED)

**Functionally irrelevant plays become ILLEGAL, not just low-scoring:** targeting legality
rejects plays whose effect would change nothing — first case: heals cannot target
full-health units. Key off "effect would change nothing", NOT off health (a full-health
heal with a shield/rider stays legal). Make it a real targeting rule (applies to the player
too), which also keeps the spendability count honest and stops wasting simulations.
- **ENGINE-SIDE FORM BUILT 2026-07-29** (forced by the mana eval — without it the engine
  burns mana on no-ops to avoid stranding): `EnemyEngine._effect_changed_nothing` vetoes
  any cast/ability whose resulting state matches the current one on OUTCOMES (units,
  positions, stats, corpses), ignoring the play's own costs (mana/tap/card). Fully general
  — catches ANY no-op cast, not just heals. Known limit: a pure-marker status folding into
  no captured stat would be wrongly vetoed. The PLAYER-facing targeting rule is still
  pending.

## Authoring model — **BUILT 2026-07-30 as PERSONALITIES (user-designed)**

The sketch below (per-encounter criterion weights in the template JSON) is superseded. Weights
are authored as **named characters** instead, because a set of weights IS a character and
several fights want the same one: `EnemyPersonality` (`scripts/enemy/enemy_personality.gd`),
authored in `data/enemy_personalities.json` through Tool ▸ 🧠 Enemy AI, named by an encounter
template's `personality` key.

- **Core traits vs quirks is a TOOL distinction, not an engine one (user call).** Conceptually
  they are the same thing — a criterion and a weight. Core traits (everything except damage
  output today) are always present and can only be re-priced; a blank one keeps the const.
  Quirks are added and removed freely, and an uncarried quirk is *not constructed at all* —
  identical arithmetic to weight 0, but the criterion dump stays honest about who is in the
  room. That presence rule is the split's one mechanical consequence.
- **The consts in `board_scoring.gd` are now DEFAULTS, not the values in use.** They remain the
  single source of truth for the stock character (all the reasoning recorded on them still
  applies) — a personality inherits any weight it does not state.
- **Survival weights are part of the personality**, with the encounter's own table layering on
  top for one-off fights. Both were kept: the personality states the character's standing
  protect ordering, the encounter amends it for that fight.
- **No personality = the old engine, exactly** — absent file, unknown id, null personality all
  build the pre-2026-07-30 scorer. Pinned by `tests/test_enemy_personality.gd`, which also pins
  the anti-decoration property (weights must be able to change a decision) and the
  absent-vs-empty `quirks` distinction. Suite 1086/1086.
- **Shipped starters (`aggressive`, `defensive`, `board_oriented`) are directions, not balance**
  — authored by reading the criteria, never playtested. Same standing caution as every weight.
- Still open from the sketch: the `target_values` table (per-card-id/role value overrides) was
  never needed, since board value replaced the mana-cost pricing.

## Order of work (recommendation, not mandate)

1. Value-harm goal — reuses `ExpectedHarm` math + weight-table plumbing.
2. No-op legality rule (heals at full health) — independent, small, benefits everything.
3. Spendability criterion — pure function, easy tests.
4. Behavior machinery (cohort-relative contract) + aggression behavior — the only
   structural change; do it last, and resolve the OPEN question with the user first.

## Open, not yet addressed: greedy prefers ONE big body to several small ones

Surfaced while sweeping realistic turn shapes on 2026-07-30, NOT fixed, NOT user-reviewed.
With 5 mana and a hand of fodder(1) + dps(2) + tank(2) + queen(5) under light threat, the
engine spends the whole turn on the queen and fields ONE unit, where the three cheap
bodies would also have spent exactly 5 and fielded three.

Why: the greedy loop picks ONE action at a time, so the first pick compares *queen alone*
against *fodder alone* — and the queen wins on raw board value and damage output. Both
lines score a perfect 1 on mana (both spend everything), so the mana criterion cannot
break the tie. Board value's RAW measure does prefer the three bodies (≈20.5 vs ≈11.5),
but min-max normalization plus a 0.05 weight mutes that to nothing, and within a
single-unit-vs-single-unit pick it points the other way regardless.

This is the documented greedy limitation ("misses two-move combos"), now with teeth
because value is no longer linear in mana the way `presence_value` was. Fixing it properly
needs either lookahead or a per-mana notion of value — a design decision, not a tune.

## Standing cautions

- **Every weight is provisional until the user playtests.** The survival round proved the
  loop: staged probes suggest a number, regression tests pin it, but only the user's
  playtest validates it. Never cite the suite as evidence a weight is right.
- `BoardPresence` remains the one criterion in a foreign currency (Σ mana cost, patched
  with a small weight). If the "weighted fractions of life" currency becomes the standard,
  it should eventually be re-expressed — noted, not scheduled.
- Work in short loops with the user; assume steps need reframing. Plain language in
  summaries — no jargon-dense recaps.
- Suite runner: `tests/_runner.tscn`; new `class_name` scripts need a headless `--import`
  pass first. Known pre-existing failure mode: test_materials.gd silently truncates on the
  missing "blight_material" ability.
