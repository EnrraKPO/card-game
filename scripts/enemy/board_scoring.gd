class_name BoardScoring
extends RefCounted

# Scores a hypothetical board state against the encounter's priorities (design decision 17:
# priorities are ways of scoring a board). Static POSITION measurement only — no combat
# resolution, no concrete "X will attack Y" projection (17a/17b).
#
# A criteria LIST from day one (the extension test demands new criteria touch nothing but
# this list). Day one it holds one entry: protection-weighted exposure.

# The criteria this scorer runs, in order. Each entry: a Criterion. Total score is the
# weighted sum; HIGHER IS BETTER (a "goal alignment" value).
var criteria: Array = []


# The stock day-one setup: protect the Captain (weight table Captain = 1, default = 0 —
# the mandated general form, so rebalancing protection across units is a DATA change).
static func stock() -> BoardScoring:
	var s := BoardScoring.new()
	s.criteria.append(ProtectionExposure.new({"captain": 1.0, "default": 0.0}))
	return s


func score(state: BoardState) -> float:
	var total := 0.0
	for c: Criterion in criteria:
		total += c.weight * c.score(state)
	return total


class Criterion:
	extends RefCounted
	var id: String = ""
	var weight: float = 1.0
	# Higher is better. Override.
	func score(_state: BoardState) -> float:
		return 0.0


# Protection-weighted exposure over ALL own units: Σ protect_weight(unit) × exposure(slot),
# minimized — so the criterion's score is the NEGATED sum. Day-one weights make this
# "screen the Captain"; giving other units nonzero weights (later, via tags) rebalances
# protection — including the Captain itself tanking for a more valuable unit — with zero
# structural change (design Part 5, user-mandated form).
class ProtectionExposure:
	extends Criterion

	# "captain" and "default" keys, plus optional per-card-id overrides.
	var protect_weights: Dictionary = {}

	func _init(weights: Dictionary) -> void:
		id = "protection"
		protect_weights = weights

	func score(state: BoardState) -> float:
		var exposed := 0.0
		for u: BoardState.UnitState in state.units(1):
			var w := protect_weight(u)
			if w != 0.0:
				exposed += w * BoardScoring.exposure(state, u.row, u.col)
		return -exposed

	func protect_weight(u: BoardState.UnitState) -> float:
		if protect_weights.has(u.card_id):
			return float(protect_weights[u.card_id])
		if u.is_king and protect_weights.has("captain"):
			return float(protect_weights["captain"])
		return float(protect_weights.get("default", 0.0))


# ── The exposure function (v1 — invented here, expected to be revised) ─────────────────
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
