class_name BoardScoring
extends RefCounted

# Scores a hypothetical board state against the encounter's priorities (design decision 17:
# priorities are ways of scoring a board). Static POSITION measurement only — no combat
# resolution, no concrete "X will attack Y" projection (17a/17b).
#
# Two criteria, softly combined (weight × urgency — the deliverable-2 model):
#   1. DEATH RISK (dominant): Σ survival_weight × P(death). Dead quiet when nothing on the
#      player's board can hurt anyone; dominates the moment real threat exists, so a dying
#      low-value unit outweighs marginal protection of a comfortable high-value one.
#   2. BARE EXPOSURE (small): the deliverable-1 criterion, kept as the quiet second entry so
#      formation-building never dies — with an empty player board (the CPU places FIRST each
#      round) every urgency is 0 and this is what still screens the Captain.
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
# body is cheaper than the exposure it absorbs — priced any higher, screening scores as a
# net loss and the engine hides everyone in the back (observed; the test suite pins it).
#
# Captain 1.75 is a MEASURED sweet spot (probed 1.0→2.5 on staged boards, 2026-07-29),
# and the behaviour is threat-dependent and decisive in both directions:
#   · moderate threat → the king walks fully to the FRONT LINE and absorbs hits for
#     units it values (the damage-sharing its 11-point pool makes cheap);
#   · heavy threat → it commits fully to the BACK COLUMN, no mid-column stop.
# Below ~1.5 the pool reads as the cheapest damage sponge — the scorer parks the king
# mid-column to soak share, hands the safe back seat to a fodder, and wanders it forward
# during placements ("takes too much damage, won't commit to retreating"). At 2.0+ the
# sharing dies entirely and the king never takes a hit. Author outside the stock only
# with intent: {"captain": 1.0} = a reckless sponge, {"captain": 2.5} = a total coward.

# How loud bare exposure is next to death risk. Small on purpose: it exists to keep the
# formation instinct alive on quiet boards, not to compete with actual mortal danger.
const EXPOSURE_CRITERION_WEIGHT := 0.15


# The stock setup. `weight_overrides` layers an encounter's own role→weight entries over the
# stock table ("in THIS fight, fodders are precious") — see EncounterData.survival_weights.
static func stock(weight_overrides: Dictionary = {}) -> BoardScoring:
	var weights := STOCK_SURVIVAL_WEIGHTS.duplicate()
	for key: String in weight_overrides:
		weights[key] = float(weight_overrides[key])
	var s := BoardScoring.new()
	s.criteria.append(DeathRisk.new(weights))
	var exposure_criterion := ProtectionExposure.new(weights)
	exposure_criterion.weight = EXPOSURE_CRITERION_WEIGHT
	s.criteria.append(exposure_criterion)
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
		return -risk


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


# Total damage the player's board can put out per round: Σ attack × strikes over fielded
# units. Visible stats only — reading the enemy's fielded army is not predicting targeting.
static func threat_mass(state: BoardState) -> float:
	var total := 0.0
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
