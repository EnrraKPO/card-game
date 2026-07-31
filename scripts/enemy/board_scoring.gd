class_name BoardScoring
extends RefCounted

# Scores a hypothetical board state against the encounter's priorities (design decision 17:
# priorities are ways of scoring a board). Static POSITION measurement only — no combat
# resolution, no concrete "X will attack Y" projection (17a/17b).
#
# The criteria, softly combined (weight × urgency — the deliverable-2 model):
#   1. DEATH RISK (dominant): Σ survival_weight × P(death) — a dying low-value unit
#      outweighs marginal protection of a comfortable high-value one.
#   2. EXPECTED HARM (half): Σ survival_weight × harm — being worn down matters even when
#      the unit survives; only damage past the shield counts, proportional to max health.
#   3. BARE EXPOSURE (small): the deliverable-1 criterion, kept as the quiet entry so
#      formation-building never dies even when the threat measurements go silent.
#   4. BOARD VALUE (small): the net worth of the battlefield — every unit priced by its
#      stats + abilities + effects (BoardValueConfig exchange rates), own side positive,
#      player side negative; min-max normalized within the pick (worst 0, best 1).
#      REPLACED BoardPresence (user call 2026-07-29): same fielding-pole job, real
#      currency instead of mana cost — and it prices hurting the player too.
#   5. DAMAGE OUTPUT (small, positive): aggression as expression — the first BEHAVIOR
#      criterion (EVAL_CRITERIA_BRIEF.md): cohort-relative, scored through score_pick.
#   6. MANA OPTIMIZATION (loud): use your mana — spending counts, waste doesn't. THE
#      fielding pressure (user-designed 2026-07-29): withholding playable units is
#      leaving spendable mana unspent.
#   7. READINESS (moderate): the OTHER resource a play spends — a tap. Keeps "don't tap"
#      a live option against 6's pressure to spend mana on abilities.
#   8. IDLE HAND (harsh): a choice that spends NO mana while the CPU is holding a unit it
#      could field is charged the full weight per withheld body. The blunt instrument (user
#      mandate 2026-07-30) — a direct reading of the withheld cards themselves, not an
#      inference from the mana pool. Spending mana waives it: the target is idleness, not
#      the choice between two paid plays.
# Threat includes the player's OPEN MANA at 1:1 (MANA_THREAT_RATE), so risk and harm are
# live from turn one — unspent mana is damage the player can still convert.
#
# Survival weights are resolved from unit ROLE tags (design decision 18): the unit says what
# it is (CardData.role), the weight table says what that's worth — stock defaults below,
# overridable per encounter. The scorer itself stays tag-agnostic: criteria receive resolved
# weights and know nothing about the word "fodder". Tags are never load-bearing — an untagged
# unit falls to the "default" entry and is handled correctly.

# The criteria this scorer runs. Total score is the weighted sum; HIGHER IS BETTER (a "goal
# alignment" value). New criteria are entries here — nothing outside this list changes.
var criteria: Array = []

# ⚠ EVERY *_CRITERION_WEIGHT CONSTANT BELOW IS NOW A DEFAULT, NOT THE VALUE IN USE. A fight
# is scored through an EnemyPersonality (an authored character in data/enemy_personalities.
# json, Tool ▸ 🧠 Enemy AI), which may state its own weight for any criterion; these consts
# are what it inherits when it doesn't, and they remain the single source of truth for the
# stock character — the reasoning recorded on each one is still the reasoning behind the
# default enemy. Change a const to move every personality that hasn't opinionated away from
# it; author a personality to make ONE enemy different.

# Stock survival-weight table, keyed by role tag ("captain" = any is_king unit; per-card-id
# overrides also allowed). The values encode the default protect ordering: the Captain far
# above everything, support/burst worth shielding, fodder cheap, untagged mid-low.
const STOCK_SURVIVAL_WEIGHTS := {
	"captain": 1.75,
	"support": 0.5,
	"burst": 0.4,
	"dps": 0.3,
	"tank": 0.15,
	"fodder": 0.05,
	"default": 0.1,
}
# Fodder/default sit LOW deliberately: a screen is only worth standing in the open if the
# body is cheaper than the exposure it absorbs — priced any higher, screening scored as a
# net loss and the engine hid everyone in the back, on the suite's staged boards.
#
# ⚠ ALL VALUES HERE ARE PROVISIONAL — NONE HAVE BEEN PLAYTESTED. They were arrived at by
# walking weights across scenarios staged inside tests/test_enemy_engine.gd (boards this
# engine's own development invented), not by playing fights. The regression tests pin them,
# but that is self-consistency, not validation: the suite agrees with the numbers because
# both were written together. Treat every constant in this file as a first guess awaiting
# a real playtest, and do not cite the tests as evidence that a value is right.
#
# Captain 1.75, the one value with ANY play behind it: at 2.5 the user reported a fight
# where the king never took a single hit, and said the damage-sharing behaviour (the king
# absorbing blows so cheaper units survive) is wanted. 1.75 is where the staged sweep put
# that behaviour back — reading as threat-dependent on those boards: moderate threat and
# the king moves up to absorb, heavy threat and it commits to the back column. Below ~1.5
# the sweep showed the king loitering mid-column and a fodder taking the safe back seat.
# The direction (2.5 is too cowardly) is the user's; the specific number is not.
# Rough character range, same caveat: {"captain": 1.0} ≈ reckless sponge, 2.5 ≈ coward.

# How loud bare exposure is next to death risk. Small on purpose: it exists to keep the
# formation instinct alive on quiet boards, not to compete with actual mortal danger.
const EXPOSURE_CRITERION_WEIGHT := 0.15

# How loud expected HARM is next to death risk (user-mandated 2026-07-29): a unit being
# worn down matters even when it will not die — the king dropping 15→6 is an important
# reading, weighted by the same survival table (the king's 15→6 outranks the tank's 15→6).
# Half the death criterion because harm is the sub-lethal half of the same concern: losing
# the unit outright must always read worse than any amount of surviving damage. PROVISIONAL
# like every constant here — no playtest behind the specific value.
const HARM_CRITERION_WEIGHT := 0.5

# Open player mana counts as threat, 1:1 (user-mandated 2026-07-29): mana the player has
# not yet spent is damage they can still convert this round — a fresh unit, a spell. Folded
# into threat_mass, so it reaches BOTH death likelihood and expected harm through the one
# incoming() measurement. The rate is the initial guess; tune here.
const MANA_THREAT_RATE := 1.0

# How loud board value is next to death risk — THE arbitration dial between growing the
# battlefield (fielding, buffing, hurting the player) and preserving what stands. It
# inherits BoardPresence's old job of paying for placements under the must-improve rule
# (the "placements are always accepted" special case stays retired), but in the real
# currency: a unit is worth its stats + abilities + effects (BoardValueConfig), not its
# mana cost. Min-max normalized within the pick (worst 0, best 1), so the weight reads
# like every behavior weight: how much this character cares about the richest board.
# NOTE the deliberate trade: presence's linearity ("a budget converts to the same total
# however it is split") is gone — stat value is not linear in mana, so greedy ordering
# can now matter to what a spent turn is worth.
#
# ⚠ THIS WEIGHT IS AWAITING A USER DECISION (2026-07-30). They asked for board value to
# OUTWEIGH the safety criteria — the danger criteria only PROJECT future value loss, while
# this measures value directly. But raising it past ~0.1 flips a behaviour they approved
# earlier: the support stops healing its dying ally and buffs an attacker instead. That is
# not a tuning artefact, it is arithmetic — under the authored rates a +2 attack buff is
# worth 2.0 while healing a wounded unit earns ~0.9 per point, so in pure value terms
# growing always beats rescuing. Only DeathRisk sees the ally about to die.
#   0.1  → rescues the dying ally (current; every approved behaviour intact)
#   0.2+ → buffs and lets it die (board value genuinely outweighs safety)
# Held at 0.1 until the user picks which enemy they want. Note also that the criterion is
# min-max normalized, so its FULL swing is its weight: raising it amplifies even trivial
# value gaps into full-weight differences. PROVISIONAL.
const BOARD_VALUE_CRITERION_WEIGHT := 0.1

# How loud aggression is next to death risk — the "maximize damage output" BEHAVIOR
# (EVAL_CRITERIA_BRIEF.md eval 2). Behaviors land on 0..1 by construction (expression
# relative to this pick's best option), so the weight is directly "how much of a
# certainly-dying weight-1.0 unit full aggression is worth". Nonzero in stock ON PURPOSE:
# the default character must already reach for damage buffs without per-encounter
# authoring — that is the initiative's stated goal. 0.1 because at 0.25 the staged
# wounded-ally board showed the support casting fire_bless while its 1 HP dps died —
# aggression must lose to live triage in the stock character. PROVISIONAL like every
# constant here; raise per-encounter for genuinely bloodthirsty Captains.
const DAMAGE_CRITERION_WEIGHT := 0.1

# How loud "use your mana" is — deliberately the loudest dial after death risk (user
# mandate 2026-07-29: "there's no reason it should ever stop playing units"). The eval is
# a GOAL already on 0..1 (fraction of the turn's mana budget), so the weight is honest.
# Since the 2026-07-30 reshape the pressure per pick is the FULL swing — any waste-free
# spend scores 1 against declining's 0 — so the weight is exactly "what one clean use of
# mana is worth". That makes it far blunter than the old fractional version (which needed
# 3.5 to be felt at all): 0.6 already outbids a placed body's own risk share on the
# staged 2-queens repro, while staying under the weight of genuinely precious lives, so
# a play that throws away something valuable can still be declined — must-improve
# restraint survives. PROVISIONAL.
const MANA_CRITERION_WEIGHT := 0.6

# How loud keeping units READY is — the counterweight to the mana criterion (user
# 2026-07-30). Mana pressure alone would tap every unit that holds an affordable ability,
# because a tap is invisible to it: only the mana leaves the pool. But a tap spends the
# unit's whole turn — its attack AND its every other ability — so an ability is never
# just its mana cost. This prices that second resource in the same currency, which makes
# NOT tapping a genuine option: a tap on a unit with little else to give stays cheap,
# while tapping the army's best attacker has to be worth it. Deliberately below the mana
# weight — reluctance, not refusal (the user wants tapping discouraged, not prevented).
# PROVISIONAL.
const READINESS_CRITERION_WEIGHT := 0.4

# What ONE withheld playable unit costs — the harsh dial (user mandate 2026-07-30: "author
# an eval that forbids keeping units in hand"). Deliberately blunt, and deliberately NOT
# another attempt to infer withholding from the mana pool: the mana criterion has been
# rewritten three times chasing this bug through as many disguises, always reasoning about
# leftover mana. This one reads the withheld cards directly — if a body could stand on the
# board and doesn't, that is the charge, whatever the pool looks like.
#
# Read it against the survival table: at 1.0 one idle body costs as much as a certainly
# dying weight-1.0 unit, which is more than any non-captain entry (dps 0.3, support 0.5)
# and more than mana's whole swing (0.6) — so with a body in hand, a turn that spends
# nothing has to be worth more than a certain death to be chosen, which is what the user
# asked "harshly" to mean. It never argues against another PAID play, though: see the
# waiver in idle_hand(). Together the two make the statement precise — spend your mana
# while you are holding a body, and how you spend it is the other criteria's business.
#   0.0  → the criterion is off; mana pressure alone decides (the pre-2026-07-30 engine)
#   0.5  → strong preference; a valuable free move can still win a pick
#   1.0  → current: while a body is in hand, do something with the mana
# PROVISIONAL like every constant here — this one is a policy the user asked for, though,
# not a probe result.
const IDLE_HAND_CRITERION_WEIGHT := 1.0




# The scorer for one fight. The PERSONALITY says how loud each criterion is (EnemyPersonality
# — an authored character, or the stock one when none is named); `weight_overrides` layers an
# encounter's own role→weight entries on top of the personality's survival table ("in THIS
# fight, fodders are precious") — see EncounterData.survival_weights.
#
# Every criterion is built the same way whether the personality calls it a core trait or a
# quirk: the split is an authoring distinction (EnemyPersonality), not a mechanical one. The
# ONE mechanical consequence is presence — a quirk the personality does not carry is never
# constructed, so it contributes nothing rather than contributing zero (identical arithmetic,
# but the criterion dumps stay honest about who is in the room).
static func stock(weight_overrides: Dictionary = {}, personality: EnemyPersonality = null) -> BoardScoring:
	var who := personality if personality != null else EnemyPersonality.stock()
	var weights := STOCK_SURVIVAL_WEIGHTS.duplicate()
	for key: String in who.survival_weights:
		weights[key] = float(who.survival_weights[key])
	for key: String in weight_overrides:
		weights[key] = float(weight_overrides[key])
	var s := BoardScoring.new()
	for entry: Dictionary in EnemyPersonality.TRAITS:
		var trait_id := String(entry["id"])
		if not bool(entry["core"]) and not who.has_quirk(trait_id):
			continue
		var c := _criterion_for(trait_id, weights, who)
		if c == null:
			continue
		c.weight = who.weight_for(trait_id)
		s.criteria.append(c)
	return s


# Criterion id → a fresh instance. The one place the scorer's vocabulary is enumerated: a new
# criterion is a case here plus an entry in EnemyPersonality.TRAITS.
static func _criterion_for(trait_id: String, weights: Dictionary, who: EnemyPersonality) -> Criterion:
	match trait_id:
		"death_risk":    return DeathRisk.new(weights)
		"harm":          return ExpectedHarm.new(weights)
		"protection":    return ProtectionExposure.new(weights)
		"board_value":   return BoardValue.new(who)
		"mana":          return ManaOptimization.new()
		"readiness":     return Readiness.new(who)
		"idle_hand":     return IdleHand.new()
		"damage_output": return DamageOutput.new()
	push_error("BoardScoring: no criterion for trait '%s'" % trait_id)
	return null


# Scores one state alone. BEHAVIOR criteria are silent here (their base score() is 0):
# expression is relative to a pick's alternatives, which a lone state does not have — a
# decision's cohort goes through score_pick instead.
func score(state: BoardState) -> float:
	var total := 0.0
	for c: Criterion in criteria:
		total += c.weight * c.score(state)
	return total


# The behavior-criteria contract (EVAL_CRITERIA_BRIEF.md taxonomy): scores a whole pick's
# cohort at once. GOALS score each state independently, exactly like score(). BEHAVIORS
# measure every state raw, then normalize by the cohort's best measure — the strongest
# expression available this pick scores 1.0 whatever its absolute size (ratified: when a
# 1-damage flick is the best option, taking it IS maximizing damage). The caller passes
# the do-nothing baseline as the FIRST entry, so "act" and "decline" are compared in the
# same currency. Returns one total per entry, same order.
func score_pick(states: Array) -> Array:
	var totals: Array = []
	for _s in states:
		totals.append(0.0)
	for c: Criterion in criteria:
		var b := c as Behavior
		if b == null:
			for i in states.size():
				totals[i] = float(totals[i]) + c.weight * c.score(states[i])
			continue
		var raws: Array = []
		for s: BoardState in states:
			raws.append(b.measure(s))
		var norm := b.normalized(raws)
		for i in states.size():
			totals[i] = float(totals[i]) + b.weight * float(norm[i])
	return totals


# The one place a unit's protection weight is resolved: per-card-id entry first, then the
# implicit "captain" tag for kings, then the unit's role tag, then "default". Keys all live
# in the same table, so rebalancing ANY of this is a data change.
static func weight_for(u: BoardState.UnitState, weights: Dictionary) -> float:
	if weights.has(u.card_id):
		return float(weights[u.card_id])
	if u.is_king and weights.has("captain"):
		return float(weights["captain"])
	if not u.role.is_empty() and weights.has(u.role):
		return float(weights[u.role])
	return float(weights.get("default", 0.0))


class Criterion:
	extends RefCounted
	var id: String = ""
	var weight: float = 1.0
	# Higher is better. Override.
	func score(_state: BoardState) -> float:
		return 0.0


# Σ survival_weight × urgency, negated — the soft-combination criterion. Urgency is the
# unit's likelihood of dying where it stands (see urgency() below), so a much-lower-health
# cheap unit can outweigh marginal protection of a healthy expensive one, with no ordering
# gate and no special cases. A unit that dies under EVERY candidate contributes a constant
# term and cancels out of the ranking — triage for free.
class DeathRisk:
	extends Criterion

	var survival_weights: Dictionary = {}

	func _init(weights: Dictionary) -> void:
		id = "death_risk"
		survival_weights = weights

	func score(state: BoardState) -> float:
		var risk := 0.0
		for u: BoardState.UnitState in state.units(1):
			var w := BoardScoring.weight_for(u, survival_weights)
			if w != 0.0:
				risk += w * BoardScoring.urgency(state, u)
		# A unit this candidate KILLED carries its full weight — urgency 1.0 is "certainly
		# dies", and a corpse is that outcome already realised. Without this the risk term
		# of anything the simulation destroys simply disappears from the sum, and wiping out
		# your own most valuable unit becomes the highest-scoring play on the board (it was:
		# the CPU bolted its own Captain). Own side only — a dead PLAYER unit is already
		# rewarded, through the threat mass it stops contributing.
		for dead: BoardState.UnitState in state.graveyard:
			if dead.owner == 1:
				risk += BoardScoring.weight_for(dead, survival_weights)
		return -risk


# Σ survival_weight × harm, negated — the sub-lethal companion to DeathRisk: how worn down
# each unit is expected to end up, regardless of whether it dies. Same walk, same weights;
# harm() instead of urgency() — the fraction of the unit's HEALTH the incoming share eats
# after the shield soaks its part (shield damage regenerates, health damage lasts). No
# graveyard term: a corpse is DeathRisk's charge, and charging it here too would bill the
# same loss twice.
class ExpectedHarm:
	extends Criterion

	var survival_weights: Dictionary = {}

	func _init(weights: Dictionary) -> void:
		id = "harm"
		survival_weights = weights

	func score(state: BoardState) -> float:
		var hurt := 0.0
		for u: BoardState.UnitState in state.units(1):
			var w := BoardScoring.weight_for(u, survival_weights)
			if w != 0.0:
				hurt += w * BoardScoring.harm(state, u)
		return -hurt


# Σ survival_weight × exposure, negated — the deliverable-1 criterion, now sharing the same
# weight table. Runs at a small criterion weight underneath death risk (see stock()).
class ProtectionExposure:
	extends Criterion

	var survival_weights: Dictionary = {}

	func _init(weights: Dictionary) -> void:
		id = "protection"
		survival_weights = weights

	func score(state: BoardState) -> float:
		var exposed := 0.0
		for u: BoardState.UnitState in state.units(1):
			var w := BoardScoring.weight_for(u, survival_weights)
			if w != 0.0:
				exposed += w * BoardScoring.exposure(state, u.row, u.col)
		return -exposed


# The net worth of the battlefield (user-designed 2026-07-29, REPLACING BoardPresence):
# every unit priced by its full kit — stats at authored exchange rates, abilities and
# effect categories at authored equivalences (BoardValueConfig) — own side positive,
# player side negative. The positive pole the negative criteria pull against: fielding,
# buffing, healing AND hurting the player all grow it, so it prices the whole "make the
# battlefield mine" instinct in one currency. Min-max normalized over the pick's cohort:
# worst option 0, best 1, everything else its fraction of that span.
class BoardValue:
	extends Behavior

	# The fight's personality, which carries this eval's parameters (its price list). Set by
	# stock(); null = the global price list alone.
	var pricer: EnemyPersonality = null

	func _init(p_pricer: EnemyPersonality = null) -> void:
		id = "board_value"
		pricer = p_pricer

	func measure(state: BoardState) -> float:
		return BoardScoring.board_value(state, pricer)

	# Signed measures need the min-max anchoring: ratio-to-max is meaningless when the
	# whole cohort can sit below zero (a rich player board). A flat cohort maps to
	# all-zero — nothing to prefer, the criterion goes silent.
	func normalized(raws: Array) -> Array:
		var lo := INF
		var hi := -INF
		for r in raws:
			lo = minf(lo, float(r))
			hi = maxf(hi, float(r))
		var span := hi - lo
		var out: Array = []
		for r in raws:
			out.append(0.0 if span <= 0.0 else (float(r) - lo) / span)
		return out


# Use your mana (user-designed 2026-07-29, refined 2026-07-30; absorbs the brief's "spend
# all mana" eval). Scores THE CHOICE, not the turn's running total: spending nothing
# scores 0, and any spend that leaves the remainder fully usable scores 1 — spending all
# your mana and keeping a usable reserve are EQUALLY fine, only WASTE is punished. A GOAL
# on 0..1 with no cohort machinery (see mana_optimization).
#
# Two properties this shape buys. (1) The fielding pressure the withholding bug needed:
# every successive placement decision beats declining on its own, because declining
# spends nothing — the brief's stranded-only version maxed on doing nothing and could
# never push the engine to act. (2) Greedy combo blindness cured: with 5 mana and options
# 2/3/4, playing the 4 strands 1 (score 0) while playing the 3 keeps the 2 usable (1).
# Waste is judged ONLY when mana is the binding constraint — see mana_optimization.
class ManaOptimization:
	extends Criterion

	func _init() -> void:
		id = "mana"

	func score(state: BoardState) -> float:
		return BoardScoring.mana_optimization(state)


# How much of the army's ACTIVITY is still available, 0..1 — the tap counterweight
# (user 2026-07-30). A tap is a second currency the mana criterion cannot see: it spends
# the unit's attack for the round and closes every other ability it holds. Scoring the
# STATE (fraction of activity potential still unspent) is enough to price the CHOICE,
# because the must-improve gate compares each candidate against the do-nothing baseline —
# the drop between them IS what this tap costs. No cohort machinery, no prev/next
# plumbing.
class Readiness:
	extends Criterion

	# Taps are priced in the same currency board value uses, so this criterion reads the same
	# per-fight price list (see BoardValue.pricer).
	var pricer: EnemyPersonality = null

	func _init(p_pricer: EnemyPersonality = null) -> void:
		id = "readiness"
		pricer = p_pricer

	func score(state: BoardState) -> float:
		return BoardScoring.readiness(state, pricer)


# Every unit the CPU could field right now and isn't, charged one full weight each, negated
# (user mandate 2026-07-30). A GOAL measured on the resulting state, and the bluntest
# criterion in the scorer on purpose: the withholding bug has been chased through the mana
# pool three times, so this one stops reasoning about mana at all and reads the withheld
# cards. Placing a unit erases its entry, so the charge falls by exactly one weight per
# body fielded — every successive placement improves the score by the same full amount, no
# normalization to dilute it and nothing about the pool for it to be confused by.
class IdleHand:
	extends Criterion

	func _init() -> void:
		id = "idle_hand"

	func score(state: BoardState) -> float:
		return -BoardScoring.idle_hand(state)


# A BEHAVIOR criterion (EVAL_CRITERIA_BRIEF.md taxonomy): measures how fully an action
# expresses a disposition, not how good a state is — actor, not optimizer. Raw measures
# are normalized by the pick's cohort max inside score_pick; a behavior never scores a
# lone state (base score() stays 0), because expression only exists relative to what was
# available.
class Behavior:
	extends Criterion

	# The raw, un-normalized reading of one resulting state. Override.
	func measure(_state: BoardState) -> float:
		return 0.0

	# Maps the cohort's raw measures onto 0..1. Default: ratio-to-max — each option as a
	# fraction of the pick's fullest expression (assumes non-negative measures). Override
	# for other anchorings (BoardValue's signed min-max). A cohort with no expression
	# anywhere maps to all-zero: the criterion goes silent instead of dividing by zero.
	func normalized(raws: Array) -> Array:
		var peak := 0.0
		for r in raws:
			peak = maxf(peak, float(r))
		var out: Array = []
		for r in raws:
			out.append(0.0 if peak <= 0.0 else float(r) / peak)
		return out


# Aggression as expression (EVAL_CRITERIA_BRIEF.md eval 2): the candidate's resulting
# durability-weighted outgoing damage mass, normalized by the pick's best. 1.0 always means
# "the most aggressive expression available right now" — never a global ideal. Buffs,
# placements and attack-raising abilities all move it; damage SPELLS are eval 1's business
# (they hurt what is there; this grows the threat the CPU projects) — division of labor,
# no double counting.
class DamageOutput:
	extends Behavior

	func _init() -> void:
		id = "damage_output"

	func measure(state: BoardState) -> float:
		return BoardScoring.outgoing_mass(state)


# ── The measurement vocabulary ─────────────────────────────────────────────────────────
#
# Named, pure functions over a BoardState. Criteria CONSUME these; they never compute
# damage themselves — so any future sophistication in potential-damage estimation (top-4
# lane cap, per-lane threat pairing, status-based known damage, ranged reach) is an edit
# inside one function here, invisible to criteria, enumeration and selection. Do not
# inline these formulas into a criterion.

# ── exposure (v1 — invented for deliverable 1, expected to be revised) ──
#
# "How likely is something standing at this ENEMY slot to be attacked" (design 17b), from
# geometry + own-side occupancy only — deliberately blind to the player's units and their
# targeting policies (the geometry-only setting is a design decision, not an omission:
# leapers are SUPPOSED to get through).
#
# Model, derived from how nearest-targeting actually works (targeting_strategy.gd — column
# depth dominates, lane offset orders within a column; the enemy's front line is col 0):
#   · base danger falls with depth: front column 1.0 → back column 0.25;
#   · a body strictly in FRONT (lower col) screens — hardest in the same lane, since a
#     same-lane attacker reaches it first by both depth and lane;
#   · a body in the SAME column splits the column's attention a little.
# All constants are tuning surface; the Combat Gym is the judge.

const COVER_SAME_LANE := 1.0     # screener in front, same row
const COVER_OFF_LANE := 0.5      # screener in front, other row
const COVER_COLUMN_MATE := 0.25  # company in the same column


static func exposure(state: BoardState, r: int, c: int) -> float:
	var base := float(BoardData.COLS - c) / float(BoardData.COLS)
	var cover := 0.0
	for u: BoardState.UnitState in state.units(1):
		if u.row == r and u.col == c:
			continue   # the occupant itself is not its own cover
		if u.col < c:
			cover += COVER_SAME_LANE if u.row == r else COVER_OFF_LANE
		elif u.col == c:
			cover += COVER_COLUMN_MATE
	return base / (1.0 + cover)


# Total damage the player can put out per round: Σ attack × strikes over fielded units,
# PLUS their open mana at MANA_THREAT_RATE — unspent mana is damage not yet given a body.
# Visible quantities only — reading the enemy's fielded army and mana pool is not
# predicting targeting. Consequence: with mana in the pot, threat is nonzero even against
# an empty player board, so death risk and harm speak from turn one instead of leaving
# formation entirely to the exposure criterion.
static func threat_mass(state: BoardState) -> float:
	var total := float(state.player_mana) * MANA_THREAT_RATE
	for u: BoardState.UnitState in state.units(0):
		total += float(u.attack * u.strikes)
	return total


# Expected damage aimed at this enemy unit per round: the player's threat mass, apportioned
# by the unit's share of its side's total exposure. Never "X will attack Y" (17b forbids it,
# and the player can reshuffle at will) — a position measurement: "this much damage exists,
# and this unit stands in the spot that geometrically absorbs this share of it".
static func incoming(state: BoardState, unit: BoardState.UnitState) -> float:
	var total_exposure := 0.0
	for u: BoardState.UnitState in state.units(1):
		total_exposure += exposure(state, u.row, u.col)
	if total_exposure <= 0.0:
		return 0.0
	return threat_mass(state) * exposure(state, unit.row, unit.col) / total_exposure


# The unit's likelihood of dying where it stands, 0..1: expected incoming damage against
# effective remaining life (health + shield). Linear, clamped — past "certainly dead" more
# overkill adds nothing.
static func urgency(state: BoardState, unit: BoardState.UnitState) -> float:
	var life := unit.health + unit.shield
	if life <= 0:
		return 1.0
	return clampf(incoming(state, unit) / float(life), 0.0, 1.0)


# The fraction of this unit's HEALTH its incoming share is expected to eat, 0..1. The
# shield soaks first (shield loss regenerates each round; health loss lasts — and for the
# king it persists across fights), so only what gets THROUGH counts as harm. Proportional
# rather than absolute damage points on purpose: it lands on the same 0..1 scale as
# urgency, so the death and harm criteria stay commensurable, and 9 damage wounds a 15 HP
# unit far more than a 40 HP one. Distinct from urgency, which reads incoming against
# REMAINING life to ask "does it die" — this reads against MAX health to ask "how much of
# the unit is being consumed".
static func harm(state: BoardState, unit: BoardState.UnitState) -> float:
	if unit.max_health <= 0:
		return 0.0
	var through := maxf(0.0, incoming(state, unit) - float(unit.shield))
	return clampf(through / float(unit.max_health), 0.0, 1.0)


# ── outgoing damage mass (the aggression measurement, EVAL_CRITERIA_BRIEF.md eval 2) ──
#
# The CPU-side mirror of threat_mass, durability-weighted: attack stats are the ONLY way
# attack damage is visible to a static scorer (sims resolve the candidate, never the strike
# phase), and a stat is only worth what its body will live to convert — +10 attack on a
# unit that dies before swinging is nearly worthless (user-mandated 2026-07-29). All the
# aggression math lives in these three functions; refine here, invisibly to the criterion.

# Σ attack × strikes × delivery over the CPU's fielded units.
static func outgoing_mass(state: BoardState) -> float:
	var total := 0.0
	for u: BoardState.UnitState in state.units(1):
		total += float(u.attack * u.strikes) * delivery(state, u)
	return total


# A spent tap ≡ a spent attack (tap-abilities contract): a tapped unit swings nothing this
# round, so its stat is nearly worthless to THIS turn's output — capped hard rather than
# zeroed, because the stat itself survives into future turns (a buff on a tapped body is
# wasted this round, not forever). This is what prices the act of tapping: an ability whose
# cast taps its holder pays the holder's own capped output inside the candidate's score,
# so "is this worth my tap" is part of every ability's evaluation.
const TAP_DELIVERY_FACTOR := 0.1


# How much of this unit's attack stat it will live to convert, 0..1. Combat is
# speed-ordered, so the share of player threat SLOWER than the unit cannot pre-empt its
# first strike — that share of the round is insured; the rest hangs on survival
# (persistence = 1 − urgency, which already folds health, shield, cover and the actual
# threat facing the unit). A tapped unit is hard-capped: its swing this round is already
# spent (see TAP_DELIVERY_FACTOR).
static func delivery(state: BoardState, unit: BoardState.UnitState) -> float:
	var first := first_strike_share(state, unit)
	var persistence := 1.0 - urgency(state, unit)
	var base := first + (1.0 - first) * persistence
	if unit.exhausted:
		return base * TAP_DELIVERY_FACTOR
	return base


# The fraction of the player's FIELDED attack mass strictly slower than this unit — a
# static stat comparison, never "X will attack Y". Open mana is excluded on purpose: it
# has no speed stat, and its pressure already reaches persistence through urgency. No
# fielded attack at all means nothing can pre-empt anything — fully insured.
static func first_strike_share(state: BoardState, unit: BoardState.UnitState) -> float:
	var total := 0.0
	var slower := 0.0
	for u: BoardState.UnitState in state.units(0):
		var mass := float(u.attack * u.strikes)
		total += mass
		if u.speed < unit.speed:
			slower += mass
	if total <= 0.0:
		return 1.0
	return slower / total


# ── board value (the "total board value" criterion, user-designed 2026-07-29) ──────────
#
# What one unit is worth in the eval's common currency: stats at the authored exchange
# rates plus fixed equivalences for its abilities and effect categories — ALL numbers
# tool-authorable through BoardValueConfig (data/board_value.json). Replaces the old
# presence_value (mana cost): cost said what a unit COSTS, this says what it IS. All
# future shaping (diminishing returns, per-role multipliers) happens inside these two
# functions, invisible to the criterion.
# `pricer` is the fight's PERSONALITY, which carries its own partial price list layered over
# the global one (user call 2026-07-30: every eval constant is per-encounter). Null means the
# global config alone — the pre-personality behaviour, and what a lone measurement outside a
# fight reads.
static func unit_value(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	var v := float(u.attack * u.strikes) * _stat_rate(pricer, "attack")
	v += float(u.health) * _stat_rate(pricer, "health")
	v += float(u.max_health - u.health) * _stat_rate(pricer, "missing_health")
	v += float(u.shield) * _stat_rate(pricer, "shield")
	v += float(u.speed) * _stat_rate(pricer, "speed")
	for id: String in u.ability_ids:
		v += _ability_value(pricer, id)
	v += float(u.triggered_effects) * (pricer.triggered_value() if pricer != null else BoardValueConfig.triggered_value())
	v += float(u.live_effects) * (pricer.live_value() if pricer != null else BoardValueConfig.live_value())
	return v


# The two price lookups, in one place: a personality prices it if there is one, otherwise the
# global config does. Every value measurement goes through these — never BoardValueConfig
# directly, or a per-encounter price list would be silently ignored on that line.
static func _stat_rate(pricer: EnemyPersonality, key: String) -> float:
	return pricer.stat_rate(key) if pricer != null else BoardValueConfig.stat_rate(key)


static func _ability_value(pricer: EnemyPersonality, id: String) -> float:
	return pricer.ability_value(id) if pricer != null else BoardValueConfig.ability_value(id)


# The net battlefield: own units add, player units subtract. Signed on purpose — a rich
# player board IS a poor position, and killing or wounding player units raises the total
# exactly like fielding raises it.
static func board_value(state: BoardState, pricer: EnemyPersonality = null) -> float:
	var total := 0.0
	for u: BoardState.UnitState in state.units(1):
		total += unit_value(u, pricer)
	for u: BoardState.UnitState in state.units(0):
		total -= unit_value(u, pricer)
	return total


# ── readiness (the tap counterweight, user-designed 2026-07-30) ───────────────────────

# Everything a unit could do this round if left alone, in board-value currency: its swing
# plus every ability a tap would close. Non-tap abilities are excluded (they keep working
# once the unit is exhausted, so a tap does not spend them); passives too — they run
# regardless. Rates come from BoardValueConfig, so this stays tool-authored like every
# other number in the value currency.
static func activity_potential(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	var p := float(u.attack * u.strikes) * _stat_rate(pricer, "attack")
	for id: String in u.ability_ids:
		var ab := AbilityData.get_ability(id)
		if ab != null and ab.tap:
			p += _ability_value(pricer, id)
	return p


# The best single tap-ability the unit holds — what one tap can actually buy.
static func best_tap_ability(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	var best := 0.0
	for id: String in u.ability_ids:
		var ab := AbilityData.get_ability(id)
		if ab != null and ab.tap:
			best = maxf(best, _ability_value(pricer, id))
	return best


# What a spent tap COST this unit: its attack for the round plus every OTHER ability it
# holds — never the ability the tap bought, which was used, not lost (the user's exact
# model). A tap can only ever buy one ability, so crediting the unit's best one is the
# faithful reading: a one-ability unit that taps forfeits only its swing, while silencing
# a deep toolkit costs the whole rest of it. Untapped units forfeit nothing.
static func tap_forfeit(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	if not u.exhausted:
		return 0.0
	return maxf(0.0, activity_potential(u, pricer) - best_tap_ability(u, pricer))


# How much of the CPU side's activity survives, 0..1 (1 = nothing forfeited). Proportional
# on purpose: tapping your only unit spends all of your turn's agency, tapping one of
# eight spends an eighth — a tap should cost in proportion to how much of the army it
# silences. A side with nothing to activate reads 1 (nothing to lose).
static func readiness(state: BoardState, pricer: EnemyPersonality = null) -> float:
	var total := 0.0
	var forfeited := 0.0
	for u: BoardState.UnitState in state.units(1):
		total += activity_potential(u, pricer)
		forfeited += tap_forfeit(u, pricer)
	if total <= 0.0:
		return 1.0
	return 1.0 - forfeited / total


# ── idle hand (the "never withhold a unit" criterion, user-mandated 2026-07-30) ────────

# How many placeable units the CPU is holding that it COULD put on the board right now —
# the count, not a fraction: withholding two bodies is twice the offence, and the whole
# point of this criterion is that the charge never gets diluted (it is a plain sum over
# withheld cards, exactly as DeathRisk is a plain sum over endangered units).
#
# "Could play" is read narrowly and only from what the state actually knows:
#   · the card is a placeable unit — spells and kings never enter hand_unit_costs;
#   · the CPU could afford it out of the pool THIS PICK STARTED WITH (hand_budget_before,
#     not the mana left) — an unaffordable card is not withheld, it is unplayable, which is
#     the trap the mana criterion kept falling into; and reading the mana LEFT instead
#     would let any spend excuse the withholding, since draining the pool makes the held
#     body unaffordable and the charge disappear;
#   · there is somewhere to put it — a full board is not withholding.
# THE WAIVER (user 2026-07-30): a choice that SPENDS MANA is never charged. Without it the
# criterion punished using an ability — a heal costs a tap and a mana but leaves the hand
# untouched, so it carried the full charge and lost every argument to fielding a body, and
# the engine stopped rescuing dying units. That was the criterion overreaching: what the
# user is forbidding is IDLENESS while holding a playable unit, not preferring one paid
# play over another. So the charge falls on the choices that spend nothing — declining, and
# free repositioning — and any real use of the mana settles it.
#
# The fielding pressure survives the waiver because the greedy loop asks once per action:
# a turn that spends its mana on a heal comes straight back to a pick where the body is
# still in hand, and there the placement is competing against declining, which IS charged.
# So the unit still goes down — just not necessarily before the heal.
#
# Nothing here judges whether the play is GOOD; that is what the other criteria are for.
static func idle_hand(state: BoardState) -> float:
	if state.mana_spent_step > 0:
		return 0.0
	if state.hand_unit_costs.is_empty() or state.empty_slots(1).is_empty():
		return 0.0
	var idle := 0.0
	for c: Variant in state.hand_unit_costs:
		if int(c) <= state.hand_budget_before:
			idle += 1.0
	return idle


# ── mana optimization (the "use your mana" criterion, user-designed 2026-07-29) ────────

# How well THIS CHOICE uses the mana pool, 0..1 (user-specified 2026-07-30):
# THE INVARIANT, broken three times and now pinned by tests (see the enemy-engine suite,
# "THE INVARIANT"): SPENDING MANA ALWAYS SCORES STRICTLY ABOVE SPENDING NONE. A tie is a
# failure, because the engine requires strict improvement — equal-to-declining means the
# unit is never played, which is the withholding bug in every one of its disguises. The
# ratio below guarantees it structurally: a spending choice's numerator is at least its
# own cost, so its score can never reach zero, while declining is exactly zero.
#
#   · a choice that spends nothing → 0 (declining expresses nothing — this is what every
#     successive placement decision beats, which is the whole fielding pressure);
#   · otherwise → what this choice's LINE will consume (its own cost plus the most any
#     continuation can still spend) ÷ the most ANY line could have consumed from the
#     position this pick started in.
#
# That denominator is the load-bearing part: waste is only waste when a better line
# EXISTED. Judging leftover mana in absolute terms was the 2026-07-30 withholding bug —
# a real hand holds cards the CPU cannot yet afford, and with one of those lingering the
# leftover always looked stranded, so the last affordable play scored no better than
# declining and the unit stayed in hand (reported live: "plays a single fodder, never a
# dps"). Measured counterfactually, that leftover was never spendable by anyone, so
# playing the dps is an optimal line and scores 1.
#
# Everything the user asked for falls out of the one ratio, with no special cases:
#   · spend the whole pool                        → 1
#   · spend some, remainder still fully usable    → 1 (equal — only waste is punished)
#   · mana beyond what all options could cost     → 1 (abundance, not waste)
#   · squander a big spend on a small one         → low (5 mana, options 1 and 5: taking
#     the 1 consumes 1 of a possible 5 → 0.2)
#   · greedy combo blindness                      → cured (5 mana, options 2/3/4: the 4
#     strands 1 → 0.8, while the 3 or the 2 keep a perfect line → 1)
# Reads the engine-stamped mana story; a state scored outside a planning turn (total 0)
# is a constant, invisible to any ranking.
static func mana_optimization(state: BoardState) -> float:
	if state.enemy_mana_total <= 0 or state.mana_spent_step <= 0:
		return 0.0
	var capacity := state.mana_capacity_before
	if capacity <= 0:
		return 1.0   # nothing was ever spendable — any spend is an optimal line
	var achieved := state.mana_spent_step + spend_capacity(state)
	return clampf(float(achieved) / float(capacity), 0.0, 1.0)


# The most mana some subset of the still-playable options can consume from this state —
# the "best remaining line" figure both sides of the ratio above are built from.
static func spend_capacity(state: BoardState) -> int:
	if state.enemy_mana_left <= 0:
		return 0
	return largest_fit(option_costs(state), state.enemy_mana_left)


# The largest amount of the remaining mana that SOME subset of the remaining playable
# option costs can consume (the brief's stranded logic: left − this = stranded). Options
# are counted LOOSELY by design — hand-card costs plus untapped units' ability mana costs,
# no usefulness judgment, no target legality; escalate only if it misbehaves. Subset-sum
# over tiny integers: a bitset walk, capacity = mana left.
# The mana costs of everything the CPU still HAS to play from this state — hand cards
# plus untapped units' ability costs. LOOSE by design (decision recorded in the brief):
# any legal play counts, with no judgment of whether it is worth making. Not filtered by
# affordability — largest_fit skips whatever does not fit, and mana_optimization's
# counterfactual ratio already handles a card the CPU cannot yet pay for.
static func option_costs(state: BoardState) -> Array:
	var costs: Array = []
	for c: Variant in state.hand_costs:
		if int(c) > 0:
			costs.append(int(c))
	for u: BoardState.UnitState in state.units(1):
		for ab_id: String in u.ability_ids:
			var ab := AbilityData.get_ability(ab_id)
			if ab == null or ab.mana <= 0:
				continue
			if ab.tap and u.exhausted:
				continue
			costs.append(ab.mana)
	return costs


# The largest total ≤ capacity that some subset of these costs adds up to — subset-sum
# over tiny integers as a bitset walk.
static func largest_fit(costs: Array, capacity: int) -> int:
	if capacity <= 0:
		return 0
	var reachable: Array = []
	reachable.resize(capacity + 1)
	reachable.fill(false)
	reachable[0] = true
	var best := 0
	for cost: Variant in costs:
		var ci := int(cost)
		for m in range(capacity, ci - 1, -1):
			if bool(reachable[m - ci]) and not bool(reachable[m]):
				reachable[m] = true
				if m > best:
					best = m
	return best
