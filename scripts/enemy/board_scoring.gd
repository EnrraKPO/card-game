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
#   4. BOARD PRESENCE (small, positive): fielded army is worth something.
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

# How loud board presence is next to death risk — THE arbitration dial between fielding a
# new unit and preserving an existing one (a placement gains presence_value × this; a heal
# gains survival_weight × Δurgency). At 0.1, one mana of fielded unit ≈ one tenth of a
# certainly-dying default-weight unit — so a cheap body still screens into moderate danger,
# while a precious wounded unit (captain 1.75, event-priced roles) pulls the turn toward
# preservation. Raise it for a swarm that fields relentlessly, lower it for a caretaker
# that would rather keep what it has. This weight also REPLACES the engine's old
# "placements are always accepted" special case: fielding now pays for itself through the
# score, under the same must-improve rule as everything else.
const PRESENCE_CRITERION_WEIGHT := 0.1


# The stock setup. `weight_overrides` layers an encounter's own role→weight entries over the
# stock table ("in THIS fight, fodders are precious") — see EncounterData.survival_weights.
static func stock(weight_overrides: Dictionary = {}) -> BoardScoring:
	var weights := STOCK_SURVIVAL_WEIGHTS.duplicate()
	for key: String in weight_overrides:
		weights[key] = float(weight_overrides[key])
	var s := BoardScoring.new()
	s.criteria.append(DeathRisk.new(weights))
	var harm_criterion := ExpectedHarm.new(weights)
	harm_criterion.weight = HARM_CRITERION_WEIGHT
	s.criteria.append(harm_criterion)
	var exposure_criterion := ProtectionExposure.new(weights)
	exposure_criterion.weight = EXPOSURE_CRITERION_WEIGHT
	s.criteria.append(exposure_criterion)
	var presence_criterion := BoardPresence.new()
	presence_criterion.weight = PRESENCE_CRITERION_WEIGHT
	s.criteria.append(presence_criterion)
	return s


func score(state: BoardState) -> float:
	var total := 0.0
	for c: Criterion in criteria:
		total += c.weight * c.score(state)
	return total


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


# Σ presence_value over own fielded units — the positive pole the negative criteria pull
# against: it says having an army IS worth something, so fielding competes with preserving
# on one scale instead of through the old always-accept-placements special case. Weighted
# small (see PRESENCE_CRITERION_WEIGHT).
class BoardPresence:
	extends Criterion

	func _init() -> void:
		id = "presence"

	func score(state: BoardState) -> float:
		var total := 0.0
		for u: BoardState.UnitState in state.units(1):
			total += BoardScoring.presence_value(u)
		return total


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


# How much having this unit ON THE BOARD is worth, in "presence" units. v1: its mana cost,
# straight — mana is the game's value denominator, and LINEARITY is a chosen property (the
# total presence a budget converts into is the same however it is split, so greedy ordering
# never changes what a fully spent turn is worth — only which body lands first). This is
# the delicate dial the place-vs-preserve arbitration hangs on, so ALL future shaping
# happens inside this one function, invisible to every criterion:
#   · diminishing returns on a crowded board → curve on state occupancy (add a state param);
#   · "this fight wants its support fielded early" → per-role/per-card multiplier table,
#     resolved like weight_for, fed per-encounter the way survival_weights already flows;
#   · cost mispricing a unit's real board value → replace cost with an authored value stat.
static func presence_value(u: BoardState.UnitState) -> float:
	return float(u.cost)
