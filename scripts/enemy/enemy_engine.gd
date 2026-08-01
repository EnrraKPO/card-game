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

# WHO this enemy is: the criterion weights the scorer runs with (EnemyPersonality). Set by
# combat from the encounter's authored personality; null = the stock character, which is
# what every fight got before personalities existed.
var personality: EnemyPersonality = null

# The live CombatWorld cast/ability candidates simulate against (combat sets it before
# planning; see CandidateApply). Left unset — tests, harnesses — decide_actions
# synthesizes a planning world from the call's own grids and hand.
var world: CombatWorld = null

# The tie-break generator. Null = draw from the fight's `ai` stream (CombatRng), which is
# what makes a logged fight's tie-breaks replayable; an injected one overrides it, as the
# deterministic tests rely on.
var _rng: RandomNumberGenerator


func _init(rng: RandomNumberGenerator = null) -> void:
	_rng = rng   # injected for deterministic tests; null → the fight's `ai` stream


# One uniform pick in [0, n). The tie-break is its own stream on purpose: re-tuning how the
# CPU breaks ties must not re-roll the fight's dodges and crits (see CombatRng).
func _tie_break(n: int) -> int:
	if _rng != null:
		return _rng.randi_range(0, n - 1)
	return CombatRng.roll_int(0, n - 1, &"ai")


# Plans a whole CPU turn: greedily pick the best-scoring candidate, commit it to the
# working state, repeat until nothing is worth doing. Greedy one-at-a-time, with ONE
# compound exception: two-move ARRANGEMENTS (CandidateMoves.arrangements) are scored as
# single candidates, because geometry repairs are exactly the plays whose first step is
# neutral. Deeper combos (play-pairs, move-then-place) remain the open question.
#
# ONE acceptance rule for all four action kinds: the candidate must STRICTLY IMPROVE the
# scored position, or the turn is over. The old "placements are always accepted" special
# case is retired — the BoardValue criterion is what says fielding a unit is worth
# something, so a placement now pays for itself through the score like everything else
# (and CAN be declined: a body the criteria say is walking into pure loss stays in hand,
# which is decision 16's restraint arriving for free). Termination is inductive per kind:
# placements and casts consume the pool/mana, abilities spend mana or the holder's
# simulated tap, and moves are once-per-unit — every accepted candidate shrinks something.
func decide_actions(hand: Array, player_grid: Array, enemy_grid: Array, mana: int,
		player_mana: int = 0) -> Array:
	var scoring := BoardScoring.stock(weight_overrides, personality)
	var state := BoardState.capture(player_grid, enemy_grid, player_mana)
	var pool: Array = hand.duplicate()
	var remaining := mana
	# The mana story the mana-optimization criterion reads: the engine stamps it onto the
	# working state (capture can't know it) and _note_spend keeps it true per candidate.
	state.enemy_mana_total = mana
	state.enemy_mana_left = mana
	for inst: CardInstance in pool:
		state.hand_costs.append(int(inst.get_attribute("cost")))
		# The idle-hand criterion counts BODIES it could field: same legality filter as
		# CandidateMoves.placements, so a card it charges for is always one the engine
		# actually has a candidate for.
		if not inst.is_spell and not inst.data.is_king:
			state.hand_unit_costs.append(int(inst.get_attribute("cost")))
	var moved: Dictionary = {}   # CardInstance -> true once repositioned this turn
	var actions: Array = []
	# The per-turn simulation context (see CandidateApply): the live world casts copy, and
	# the accepted candidates a copy must replay to become the working world. `accepted`
	# grows AFTER each acceptance — a candidate never replays itself.
	var live := world
	if live == null:
		live = CombatWorld.new()
		live.player_grid = player_grid
		live.enemy_grid = enemy_grid
		live.player_side = CombatSide.make(0)
		live.enemy_side = CombatSide.make(1)
		live.enemy_side.hand = hand
		live.modifiers = GameData.current_modifiers
	var accepted: Array = []
	var sim := {"world": live, "accepted": accepted}
	while true:
		var cands := CandidateMoves.placements(state, pool, remaining)
		cands.append_array(CandidateMoves.moves(state, moved))
		# The reshuffle pass: two-move arrangements as single candidates, so a geometry
		# repair whose first step is score-neutral (king forward → column opens) can pass
		# the must-improve gate as a whole. Deeper reshuffles chain across picks.
		cands.append_array(CandidateMoves.arrangements(state, moved))
		cands.append_array(CandidateMoves.spells(state, pool, remaining))
		cands.append_array(CandidateMoves.abilities(state, remaining))
		if cands.is_empty():
			break
		var best := _pick_best(cands, state, scoring, sim)
		# The do-nothing baseline is scored INSIDE the same cohort (_pick_best puts the
		# current state first), so behavior criteria compare "act" and "decline" in the
		# same currency instead of inflating every candidate against a behavior-blind
		# baseline.
		if float(best["score"]) <= float(best["current"]) + TIE_EPSILON:
			break   # the best candidate improves nothing — then none do; the turn is done
		var cand: Dictionary = best["cand"]
		state = CandidateApply.apply(state, cand, sim)
		_note_spend(state, cand)
		accepted.append(cand)
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
			"arrange":
				# Two ordinary move actions — the pair was one CANDIDATE (scored as one
				# destination board), but it executes as the moves it is.
				for m: Dictionary in (cand["moves"] as Array):
					moved[m["inst"]] = true
					actions.append({"type": Action.MOVE, "inst": m["inst"],
							"row": int(m["row"]), "col": int(m["col"])})
			"cast":
				pool.erase(cand["inst"])
				actions.append({"type": Action.CAST, "inst": cand["inst"],
						"target": cand.get("target", null)})
			"ability":
				actions.append({"type": Action.GENERATE, "unit": cand["inst"],
						"ability": cand["ability"], "target": cand.get("target", null)})
	return actions


# Rank all candidates by the score of the state they produce; pick uniformly among the
# ones tied for best. TWO-PASS since the behavior criteria landed (EVAL_CRITERIA_BRIEF.md):
# every candidate is applied first, then the whole cohort — the current state (the
# do-nothing baseline, entry 0) plus every surviving candidate's result — is scored
# together through score_pick, so behaviors can normalize against this pick's best option.
# Returns { "cand": Dictionary, "score": float, "current": float } — an empty cand at
# -INF when every candidate was vetoed, which the caller reads as "nothing worth doing".
#
# CATEGORICAL VETOES BELONG TO THE JUDGES (BoardScoring.vetoes): a candidate a judge
# categorically objects to — today, one that leaves the Captain dead — is not an option
# at all. Dropped here, before the cohort forms, so a forbidden outcome never anchors a
# behavior's normalization. (Deliberately not a general "never let an own unit die":
# sacrificing a cheap body is a legitimate play, priced honestly. A phase-change boss
# that replaces its own Captain is unaffected — decision 13b fires those from a concealed
# container, never as an action the CPU chooses.)
func _pick_best(cands: Array, state: BoardState, scoring: BoardScoring,
		sim: Dictionary = {}) -> Dictionary:
	var kept: Array = []          # candidates that survive the vetoes, in order
	var cohort: Array = [state]   # entry 0 is the do-nothing baseline
	# The baseline is "spend nothing further this pick" — whatever the last accepted
	# candidate cost, declining now costs zero (the mana criterion scores the CHOICE).
	state.mana_spent_step = 0
	var achieved: Array = []   # per kept candidate: the mana its LINE of play consumes
	for cand: Dictionary in cands:
		var next := CandidateApply.apply(state, cand, sim)
		if scoring.vetoes(next):
			continue
		# The no-op legality rule (EVAL_CRITERIA_BRIEF.md): a cast whose EFFECT changes
		# nothing is not a candidate — first case caught: heals at full health. Without
		# this, the mana-optimization criterion happily burns mana on functionally
		# irrelevant plays just to avoid stranding it.
		var kind := String(cand["kind"])
		if (kind == "cast" or kind == "ability") and _effect_changed_nothing(state, next):
			continue
		_note_spend(next, cand)
		kept.append(cand)
		cohort.append(next)
		achieved.append(int(cand["cost"]) + BoardScoring.spend_capacity(next))
	if kept.is_empty():
		return {"cand": {}, "score": -INF, "current": 0.0}
	# The mana yardstick is the best line ANY REAL CANDIDATE offers — not an abstract
	# subset-sum over the hand. Derived from the cohort on purpose: it makes "spending
	# beats declining" structural rather than emergent. The best available play scores
	# exactly 1.0 and declining scores exactly 0.0, so the fielding pressure is always the
	# criterion's FULL weight. Deriving it from the hand instead lets unplayable cards —
	# an unsimulatable spell, one with no legal target — inflate the denominator until no
	# candidate can reach 1.0 and the margin over declining collapses (the withholding
	# bug), so never do that.
	var capacity := 0
	for a: Variant in achieved:
		capacity = maxi(capacity, int(a))
	# The idle-hand yardstick is the pool as it stood BEFORE this pick, so that spending the
	# mana on something else never excuses leaving a fieldable body in hand (see
	# BoardState.hand_budget_before). Stamped on the baseline too — declining carries the
	# charge, which is the whole pressure.
	var budget := state.enemy_mana_left
	for next: BoardState in cohort:
		next.mana_capacity_before = capacity
		next.hand_budget_before = budget
	# pick_terms rather than score_pick: the same arithmetic, with every criterion's term
	# kept, so the combat log's reasoning dump explains exactly the numbers that decided
	# this pick instead of a second, separately-computed opinion of them.
	var terms := scoring.pick_terms(cohort)
	var totals: Array = []
	for t: Dictionary in terms:
		totals.append(float(t["total"]))
	var best_score := -INF
	var best: Array = []
	for i in kept.size():
		var s := float(totals[i + 1])
		if s > best_score + TIE_EPSILON:
			best_score = s
			best = [kept[i]]
		elif absf(s - best_score) <= TIE_EPSILON:
			best.append(kept[i])
	var chosen: Dictionary = best[_tie_break(best.size())]
	_log_pick(kept, terms, chosen, cands.size() - kept.size())
	return {"cand": chosen, "score": best_score, "current": float(totals[0])}


# ── The reasoning dump (debug only — see CombatLog) ────────────────────────────────────

# One pick, written out: the decision table's shares, every surviving candidate with its
# per-criterion scores and the judges' objections, the do-nothing baseline it had to beat,
# and the winner. Gated on CombatLog.verbose(), so with logging off nothing here runs.
func _log_pick(kept: Array, terms: Array, chosen: Dictionary, vetoed: int) -> void:
	if not CombatLog.verbose():
		return
	var baseline: Dictionary = terms[0]
	var head := "CPU pick #%d — %d candidates" % [CombatLog.next_pick(), kept.size()]
	if vetoed > 0:
		head += ", %d rejected (vetoed / no-op)" % vetoed
	var lines: Array = [head, "  " + _table_line(baseline),
			"  %-9.4f %s" % [float(baseline["total"]), "(decline — the do-nothing baseline)"]]
	for i in kept.size():
		var t: Dictionary = terms[i + 1]
		lines.append("  %-9.4f %-34s %s" % [float(t["total"]),
				EnemyEngine.describe(kept[i]), _terms_line(t)])
	lines.append("  ✓ %s" % EnemyEngine.describe(chosen))
	CombatLog.block(lines)


# The table itself: who holds what authority this fight (fixed for the whole fight, but
# printed per pick so a dump is readable from any point in the file).
func _table_line(sample: Dictionary) -> String:
	var parts: Array = []
	for p: Dictionary in (sample["peers"] as Array):
		parts.append("%s w%.2f→%.3f" % [p["id"], float(p["weight"]), float(p["share"])])
	return "table: " + " | ".join(parts)


# One candidate's terms: each peer's 0..1 score, then any judge that actually objected.
func _terms_line(t: Dictionary) -> String:
	var parts: Array = []
	for p: Dictionary in (t["peers"] as Array):
		parts.append("%s %.2f" % [p["id"], float(p["score"])])
	var s := " ".join(parts)
	for j: Dictionary in (t["judges"] as Array):
		if float(j["objection"]) > 0.0:
			s += "  ⚖ %s objects %.2f (×%.2f)" % [j["id"], float(j["objection"]),
					float(t["survives"])]
	return s


# A candidate in one readable phrase — card ids, not display names: a log is grepped.
static func describe(cand: Dictionary) -> String:
	if cand.is_empty():
		return "(nothing)"
	var kind := String(cand["kind"])
	if kind == "arrange":
		var parts: Array = []
		for m: Dictionary in (cand["moves"] as Array):
			var mi := m["inst"] as CardInstance
			parts.append("%s → r%dc%d" % [mi.data.id if mi != null else "?",
					int(m["row"]), int(m["col"])])
		return "arrange " + " + ".join(parts)
	var inst := cand.get("inst", null) as CardInstance
	var who := inst.data.id if inst != null else "?"
	match kind:
		"place":
			return "place %s → r%dc%d" % [who, int(cand["row"]), int(cand["col"])]
		"move":
			return "move %s → r%dc%d" % [who, int(cand["row"]), int(cand["col"])]
		"cast":
			return "cast %s%s" % [who, _at(cand)]
		"ability":
			var ab := cand.get("ability", null) as AbilityData
			return "ability %s.%s%s" % [who, ab.id if ab != null else "?", _at(cand)]
	return kind


static func _at(cand: Dictionary) -> String:
	var target := cand.get("target", null) as CardInstance
	if target == null:
		return ""
	return " on %s (r%dc%d, %s)" % [target.data.id, target.row, target.col,
			"theirs" if target.owner == 0 else "ours"]


# Keeps a candidate state's mana story true: the candidate's cost leaves the pool, and a
# played hand card takes its cost out of the spendability options. Move candidates cost 0
# and touch neither.
static func _note_spend(next: BoardState, cand: Dictionary) -> void:
	next.enemy_mana_left -= int(cand["cost"])
	next.mana_spent_step = int(cand["cost"])
	var kind := String(cand["kind"])
	if kind == "place" or kind == "cast":
		next.hand_costs.erase(int((cand["inst"] as CardInstance).get_attribute("cost")))
	if kind == "place":
		# The body left the hand — that is the idle-hand charge this placement pays off.
		next.hand_unit_costs.erase(int((cand["inst"] as CardInstance).get_attribute("cost")))


# "The effect would change nothing": the resulting state matches the current one on every
# OUTCOME — unit identities, positions, stats, corpses — deliberately IGNORING the play's
# own costs (mana, the tap, the spent card): paying for nothing is exactly what makes it
# a no-op. Keyed off outcomes rather than health, per the brief: a full-health heal with
# a shield rider produces a different state and stays legal. KNOWN LIMIT: a status whose
# effects fold into no captured stat (a pure marker) is invisible here and would be
# wrongly vetoed — revisit if such a status ever exists. (This is the engine-side form;
# the PLAYER-facing targeting rule from the brief is separate and still pending.)
static func _effect_changed_nothing(prev: BoardState, next: BoardState) -> bool:
	if next.graveyard.size() != prev.graveyard.size():
		return false
	for side in 2:
		for r in BoardData.ROWS:
			for c in BoardData.COLS:
				var a: BoardState.UnitState = prev.grid_of(side)[r][c]
				var b: BoardState.UnitState = next.grid_of(side)[r][c]
				if (a == null) != (b == null):
					return false
				if a == null:
					continue
				if a.source != b.source or a.attack != b.attack or a.health != b.health \
						or a.max_health != b.max_health or a.shield != b.shield \
						or a.speed != b.speed or a.strikes != b.strikes:
					return false
	return true
