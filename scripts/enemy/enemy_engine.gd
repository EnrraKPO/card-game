class_name EnemyEngine
extends RefCounted

# The enemy's decision-maker (ENCOUNTER_ENGINE_DESIGN.md): for each decision, enumerate
# candidate moves, SIMULATE each on a copy of the board state, score the resulting state
# against the criteria, rank, pick the best. Replaces EnemyAI (placeholder) as the CPU's
# planner; combat._execute_enemy_action stays the presentational executor.
#
# The pipeline parts live in their own seams — board_state / candidate_moves /
# candidate_apply / board_scoring — this class only runs the loop.

# The CPU's action vocabulary, executed by combat._execute_enemy_action:
#   { "type": Action.PLACE, "inst": CardInstance, "row": int, "col": int }
#   { "type": Action.MOVE,  "inst": CardInstance, "row": int, "col": int }
# CAST / GENERATE keep the placeholder's shapes; the engine emits them once their
# candidate generators exist.
enum Action { PLACE, MOVE, CAST, GENERATE }

# Ranking treats scores within this delta as tied (random tie-break among them).
const TIE_EPSILON := 0.0001

# The encounter's role→weight overrides for the survival-weight table (see
# EncounterData.survival_weights / BoardScoring.stock). Empty = stock behaviour.
var weight_overrides: Dictionary = {}

var _rng: RandomNumberGenerator


func _init(rng: RandomNumberGenerator = null) -> void:
	if rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	else:
		_rng = rng   # injected for deterministic tests


# Plans a whole CPU turn: greedily pick the best-scoring candidate, commit it to the
# working state, repeat until nothing is worth doing. Greedy one-at-a-time is the design's
# open question (misses two-move combos) — deliberate for now.
#
# Placements and moves obey different acceptance rules. Placements are always worth
# taking (field the army; an unspent unit does nothing). A MOVE must PAY FOR ITSELF —
# strictly improve the position — or the unit stays put: free actions accepted on ties
# would jitter forever, and the must-improve gate plus one-move-per-unit-per-turn is
# what guarantees the loop terminates.
func decide_actions(hand: Array, player_grid: Array, enemy_grid: Array, mana: int) -> Array:
	var scoring := BoardScoring.stock(weight_overrides)
	var state := BoardState.capture(player_grid, enemy_grid)
	var pool: Array = hand.duplicate()
	var remaining := mana
	var moved: Dictionary = {}   # CardInstance -> true once repositioned this turn
	var actions: Array = []
	while true:
		var current := scoring.score(state)
		var cands := CandidateMoves.placements(state, pool, remaining)
		cands.append_array(CandidateMoves.moves(state, moved))
		if cands.is_empty():
			break
		var best := _pick_best(cands, state, scoring)
		var cand: Dictionary = best["cand"]
		if String(cand["kind"]) == "move" and float(best["score"]) <= current + TIE_EPSILON:
			# The best candidate is a move that doesn't improve anything — then no move
			# does (it outscored them all). Fall back to fielding the army.
			cands = CandidateMoves.placements(state, pool, remaining)
			if cands.is_empty():
				break
			best = _pick_best(cands, state, scoring)
			cand = best["cand"]
		state = CandidateApply.apply(state, cand)
		match String(cand["kind"]):
			"place":
				pool.erase(cand["inst"])
				remaining -= int(cand["cost"])
				actions.append({"type": Action.PLACE, "inst": cand["inst"],
						"row": int(cand["row"]), "col": int(cand["col"])})
			"move":
				moved[cand["inst"]] = true
				actions.append({"type": Action.MOVE, "inst": cand["inst"],
						"row": int(cand["row"]), "col": int(cand["col"])})
	return actions


# Rank all candidates by the score of the state they produce; pick uniformly among the
# ones tied for best. Returns { "cand": Dictionary, "score": float }.
func _pick_best(cands: Array, state: BoardState, scoring: BoardScoring) -> Dictionary:
	var best_score := -INF
	var best: Array = []
	for cand: Dictionary in cands:
		var s := scoring.score(CandidateApply.apply(state, cand))
		if s > best_score + TIE_EPSILON:
			best_score = s
			best = [cand]
		elif absf(s - best_score) <= TIE_EPSILON:
			best.append(cand)
	return {"cand": best[_rng.randi_range(0, best.size() - 1)], "score": best_score}
