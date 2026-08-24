# Brief: Status-Aware Enemy Evals — the appointed solution

Status: **DESIGN SETTLED 2026-08-05 (refined same day), nothing built.** This tracks
the design discussion for making the enemy engine account for statuses (unit-layer AND
ground-layer), the solution we appointed, and the options we walked through and
discarded. Read alongside `EVAL_CRITERIA_BRIEF.md` (the scoring system this extends)
and `SLOT_LAYER_DESIGN.md` (the ground layer; its §6 fence — "enemy engine: NOTHING" —
is lifted by this work).

**Design evolution, same day:** the first settled form was ONE authored value-units
number per STATUS (`eval_coefficient`). Two refinements superseded it before anything
was built:

1. **Two directional channels instead of one value number.** The engine already
   computes a chain — threat (damage a side can deliver) → per-unit incoming share →
   urgency/persistence → value discount. Statuses should enter at the TOP of that
   chain, not the bottom: fire is *incoming damage*, blind is *reduced outgoing
   damage*. Value then falls out of the existing machinery for the correct reason
   (a burning unit is worth less BECAUSE it's likely to die). A third channel remains
   for effects that are neither damage-in nor damage-out.
2. **Effect-level, not status-level.** A status is just one CARRIER of effects — so is
   a card's triggered ability, so is an innate. "Deals 1 damage whenever X" is threat
   whether it rides a status, a card, or an innate. The annotation lives on the
   EFFECT; every carrier is priced by one mechanism; statuses stop being special.
3. **Two levels + add/mul (the stacks round).** Effect-level annotations are FLAT
   (effects don't know stacks); the status gains its own per-stack annotation level
   (stacks are a status-only concept). And each annotation is add-or-mul, muls after
   adds — blind's "halve output regardless of stacks" is an effect-level threat mul,
   burning's "+1 per stack" a status-level exposure add.

## The problem

The enemy engine is entirely status-blind, in four distinct layers:

1. **The read model has no status vocabulary.** `BoardState.UnitState`
   (`board_state.gd:87`) captures stats only. A status that changes no attribute
   (ablaze, any marker/DoT) captures byte-identical to no status. `BoardState.capture`
   never touches `CombatWorld.slots` — the ground layer is structurally absent.
2. **The no-op veto ate status plays — RESOLVED BY REMOVAL 2026-08-05.**
   `EnemyEngine._effect_changed_nothing` compared units/positions/stats/graveyard only,
   so a cast whose whole outcome was a status read as a no-op and was removed from the
   cohort. Per user ruling the veto was DELETED outright; status plays are castable.
   Accepted cost: the engine can also buy genuinely outcome-free plays (full-health
   heals) rather than strand mana.
3. **The threat model has no status term.** `threat_against` (`board_scoring.gd:959`)
   is attack × strikes + open mana; the waterfall, urgency, harm and persistence all
   drink from it, so standing damage (burning ground, ablaze) is invisible to every
   survival judgment.
4. **Placements/moves are pure geometry** on a worldless `BoardState` copy —
   "don't step onto the burning tile" is inexpressible.

And the same blindness extends beyond statuses: the engine is equally blind to
triggered/standing effects carried by cards themselves. Fire (burning/ablaze) is merely
the first case forcing the issue; the ruling was explicitly "solve the general thing,
not fire."

## Requirements (user ruling)

- **Approximately correct** — not perfect.
- **Extendible to higher granularity per feature** — an effect that deserves better
  treatment gets it locally.
- **Clean and modular** — every problem has ONE enclosed solution. No bag of cats.
- Additionally, from the expectation-vs-sample round: the engine must act on **what may
  happen, not what happened to happen** in one simulated draw, and every score must be
  **deterministic and auditable** — a misplay hunt is an audit, not an excavation.

## The appointed solution — authored channel annotations, two levels, add/mul

Hand-authored annotations on **three channels** (field names provisional):

- **`eval_threat`** — *"I'm dangerous"*: expected damage per turn added to (positive)
  or removed from (negative) the carrier's OUTPUT. "Deals 1 damage to a random enemy
  every turn": +1. Blind: ×0.5.
- **`eval_exposure`** — *"I'm in danger"*: expected damage per turn onto the CARRIER.
  Burning: +1 per stack. A ward that soaks a point each round: −1.
- **`eval_value`** — the third slot, for effects that are neither damage-in nor
  damage-out (grants, mana effects, markers). Value-units (a point of attack ≈ 1),
  added directly in the valuation pass. Expected to be the RARE channel.

**Two authoring levels (user-designed 2026-08-05).** Stacks are a status-only concept,
so each quantity is annotated at the level where it lives:

- **Effect-level = flat, applied once.** Effects are the universal carrier vocabulary
  (cards, innates, statuses) and know nothing of stacks. Present = applied. Blind's
  "halve output" lives here.
- **Status-level = per stack, × stacks.** The stack-scaling number belongs to the
  status itself. Burning's "exposure +1 per stack" lives here; so does blind's "each
  stack shaves a little value".

**Each annotation is a number plus an op — `add` (default) or `mul`** — mirroring the
effect language's own idiom (interceptors already speak add/mul). Additive currency
can't say "half of whatever this unit's attack is"; mul can. **All muls apply AFTER
all adds** (per channel, per unit — settled, user ruling). Per channel the capture
fold stamps an (add, mul) pair:

    add = Σ flat effect adds + Σ status adds × stacks      mul = Π all muls
    channel reading = (base + add) × mul     # base = the unit's native quantity,
                                             # e.g. attack×strikes on threat; 0 where
                                             # there is no native base (exposure)

**Consumption**: at `BoardState` capture time, each unit's carried annotations fold
into **the per-channel (add, mul) pairs on `UnitState`** (threat, exposure, value).
The engine's existing quantities each drink theirs at their own site:
`threat_against` takes the side's threat mods; the incoming-share/urgency
measurement takes the unit's exposure mod; `run_valuation` takes the value mod. Value
needs no status math of its own for damage statuses — exposure raises urgency, urgency
lowers persistence, persistence discounts value, all through machinery that already
exists. The side-signing valuation already does makes a debuff on a player unit
automatically read as good for the CPU.

(Threat muls need the unit's own base output folded before the mul bites — the capture
fold stamps the mods; the consumption site applies them around the unit's native
contribution. Exact plumbing settled at increment 3.)

**Ground statuses price the seat the same way**: a slot's statuses sum into the same
per-seat floats; occupants inherit them into their own totals, and empty statused
slots make placement/move candidates onto them worth more or less.

Why this fits the requirements:

- **The currency is honest.** Threat and exposure are in DAMAGE POINTS per turn — for
  most statuses the number is read straight off the definition ("burning deals 1 per
  stack per round" → exposure +1/stack), barely a judgment call. Expected lifetime,
  proc chances, spread menace: baked into the authored number by the author.
- **Linearity is natural, not a compromise**: damage-per-stack × stacks is how these
  statuses actually work — the runtime itself says "stacks ARE the quantity"
  (`status_engine.gd`), and additive resolution already scales × stacks. "Risk of
  taking damage" translates to "damage expected"; "threat" translates to "damage
  dealt." Non-scaling payloads are covered by construction: they're annotated at the
  flat EFFECT level, or ride refresh-stacking statuses whose stacks never exceed 1.
  A genuinely non-linear status gets a per-status escalation LATER, enclosed.
- **Authored, never derived — the hard line.** The number sits NEXT TO the effect as a
  human annotation. The moment we compute it FROM what the effect does, we are
  rebuilding the discarded channel-taxonomy appraiser (bag of cats). The author reads
  the effect, writes the number, done.
- **Absent = invisible, per effect.** Unannotated effects contribute nothing — which
  degrades to exactly today's behavior everywhere, including the entire unpriced back
  catalog of card effects. No obligation to annotate anything retroactively.
- **Deterministic and trivially auditable**: same board, same score; an effect's whole
  contribution is one addition a log line can print.
- **Granular control is the feature**: per-effect tuning without touching engine code.
  Precedent: `unit_values` per-card enhancers — the valuation already speaks this idiom.
- **The read model gets SIMPLER than the first settled design**: `BoardState` forwards
  per-channel (add, mul) pairs per unit (+ per seat), not a status vocabulary — and
  stacks never travel; they're consumed at capture where the live world holds them.
- **Authoring surface**: fields on the effect dicts (status JSON, card JSON, innate
  JSON) + the Tool's editors.
- **Calibration aid (someday, optional)**: differential simulation OFFLINE in the
  Tool — sim a board with and without the effect, difference the outcomes, let that
  suggest a number. Sims advising the author, never running in the engine.

## The increments (in order; each stands alone)

1. **Capture** — capture-time aggregation: each unit's carried annotations (flat
   effect-level + status-level × stacks) fold into per-channel (add, mul) pairs on
   `UnitState`; each slot's ground statuses likewise into per-seat pairs on a
   `BoardState` ground map. Forwarded in
   THE THREE PLACES (`BoardState.copy()`, `CandidateApply._capture_back`, engine
   stamping — see EVAL_CRITERIA_BRIEF.md §Supporting rules). Consumed by NOTHING.
   Pure plumbing, verifiable alone. (All sums are zero until annotations exist.)
2. **The veto arm — SUPERSEDED 2026-08-05**: the veto was removed outright instead
   (user ruling; see problem layer 2). Nothing to build here.
3. **The channels** — the annotation fields (effect-level flat + status-level
   per-stack, each add-or-mul) + the three consumption sites (`threat_against`, the
   incoming/urgency measurement, `run_valuation`), muls after adds around the native
   base. First moment behavior can change. First annotations: burning/ablaze exposure
   add, blind threat mul.
4. **Ground for seats** — per-seat floats reach occupant totals and empty-seat
   desirability for placements/moves ("don't stand in fire").

Steps 1–2 are zero-behavior-change groundwork. Nothing is built as of this writing.

## Discarded options (the road here — do not reopen without new evidence)

Walked in order; each discard shaped the requirements above.

1. **Fire-specific plumbing** (wire burn damage into `threat_against`, ablaze into
   persistence, by hand). Discarded: bespoke one-off; the next status re-litigates
   everything. The problem was ruled to be statuses-in-general (and then, in the
   refinement, effects-in-general).
2. **Status appraisal layer with a channel taxonomy** (generic appraiser DERIVES
   per-status readings — expected DoT, healing, denial, lifetime — onto a closed channel
   vocabulary; per-status refinement registry). Discarded as **the bag of cats**: the
   triggered arm of a status can say anything the effect system can say, so the channel
   set is a lossy parallel semantics of the effect language that accretes a channel per
   feature. "Deal damage" is the EASY case and rarely what statuses do. NOTE the
   appointed solution's three channels are NOT this coming back: these are authored
   annotations a human writes, never a machine derivation from effect semantics —
   that distinction is the whole discard.
3. **Sampled combat rollout** (run real combat round(s) on the candidate's world copy,
   price the aftermath; optionally with a best-player-reply ply). Two discards:
   - One round only *mitigates*: the aftermath board still carries the statuses
     themselves, unpriced — blindness moved one round into the future, not removed.
   - Fundamentally, a sample is not knowledge: a blind unit and its clean twin price
     identically on any draw where the dice didn't proc — decisions fall to coin flips.
     And sampled scores are a **debugging catastrophe** (breaks the seeded-repro
     doctrine; "why did it misplay" starts in fog). The player-reply ply also drags in
     the cheating-AI question (does the CPU read the player's hand) — never resolved,
     moot after discard.
4. **Expectation-mode rollout** (run the real rules forward with dice replaced by
   expectation at the `CombatRng` sites — deterministic expected future; fractional
   stacks/HP, survival probabilities). The most correct candidate; discarded as **not
   worth the complexity**: expectation-izing the rules engine plus the discreteness
   swamp (fractional deaths, occupancy, thresholds) is heavy machinery for a system
   that only needs approximate correctness. Its one legacy: differential rollout kept
   as an OFFLINE calibration diagnostic (above).
5. **Single status-level value coefficient** (`eval_coefficient`, the first settled
   form of THIS design). Superseded, not discarded-for-cause: the two-channel
   refinement prices danger where the engine already reasons about danger (letting
   urgency/persistence carry it into value for the right reason), and the effect-level
   move prices every carrier of effects, not statuses alone. The value channel
   survives as the third slot.

## Open

- Field names (`eval_threat` / `eval_exposure` / `eval_value`?) and exact JSON/Tool
  authoring shape (effect dicts + status root; how add-vs-mul is spelled).
- Where the exposure mod enters the incoming measurement exactly (alongside the
  waterfall share, before urgency reads it), and where the threat mul wraps the unit's
  native output — settle at increment 3.
- Ground-map shape in `BoardState` (per-seat (add, mul) summary; exact structure).
- First annotation values for burning/ablaze/blind — authoring, gated on playtest.
- Whether step 4 prices empty seats inside Formation/exposure or as a value term on the
  candidate — settle when we get there.
- Per the standing doctrine (`EVAL_CRITERIA_BRIEF.md` §Testing): computation tests only
  — capture fidelity, three-places forwarding, aggregation math, per-channel
  consumption. Never pin which move the engine picks.
