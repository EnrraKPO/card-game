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
#   { "type": Action.PLACE,    "inst": CardInstance, "row": int, "col": int }
#   { "type": Action.MOVE,     "inst": CardInstance, "row": int, "col": int }
#   { "type": Action.CAST,     "inst": CardInstance(spell), "target": CardInstance|null }
#   { "type": Action.GENERATE, "unit": CardInstance(holder), "ability": AbilityData,
#     "target": CardInstance|null }   (the material row/col form stays placeholder-only —
#     material abilities are not enumerated yet, see CandidateMoves.abilities)
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
# ONE acceptance rule for all four action kinds: the candidate must STRICTLY IMPROVE the
# scored position, or the turn is over. The old "placements are always accepted" special
# case is retired — the BoardPresence criterion is what says fielding a unit is worth
# something, so a placement now pays for itself through the score like everything else
# (and CAN be declined: a body the criteria say is walking into pure loss stays in hand,
# which is decision 16's restraint arriving for free). Termination is inductive per kind:
# placements and casts consume the pool/mana, abilities spend mana or the holder's
# simulated tap, and moves are once-per-unit — every accepted candidate shrinks something.
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
		cands.append_array(CandidateMoves.spells(state, pool, remaining))
		cands.append_array(CandidateMoves.abilities(state, remaining))
		if cands.is_empty():
			break
		var best := _pick_best(cands, state, scoring)
		if float(best["score"]) <= current + TIE_EPSILON:
			break   # the best candidate improves nothing — then none do; the turn is done
		var cand: Dictionary = best["cand"]
		state = CandidateApply.apply(state, cand)
		remaining -= int(cand["cost"])
		match String(cand["kind"]):
			"place":
				pool.erase(cand["inst"])
				# A just-placed unit landed at its best slot — re-moving it the same turn
				# is churn the player reads as jitter, so it counts as this turn's move.
				moved[cand["inst"]] = true
				actions.append({"type": Action.PLACE, "inst": cand["inst"],
						"row": int(cand["row"]), "col": int(cand["col"])})
			"move":
				moved[cand["inst"]] = true
				actions.append({"type": Action.MOVE, "inst": cand["inst"],
						"row": int(cand["row"]), "col": int(cand["col"])})
			"cast":
				pool.erase(cand["inst"])
				actions.append({"type": Action.CAST, "inst": cand["inst"],
						"target": cand.get("target", null)})
			"ability":
				actions.append({"type": Action.GENERATE, "unit": cand["inst"],
						"ability": cand["ability"], "target": cand.get("target", null)})
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
