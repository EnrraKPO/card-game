extends TestCase

# The enemy engine's decision pipeline (ENCOUNTER_ENGINE_DESIGN.md Part 5): plain-data
# board state, candidate enumeration, apply, measurement vocabulary, the decision table.
#
# TESTING DOCTRINE (user ruling 2026-07-31): tests validate that the COMPUTATION happens
# as specified — measurements, algebra, plumbing, purity, and that dials reach the
# decision. They never enforce a BEHAVIOR (which move the engine picks on a staged
# board); behaviors are judged by playtest observation only. The old behavior pins kept
# passing through every failed iteration of the system and were kept green with staged
# repricing more than once — they measured the fixtures, not the engine.


func suite_name() -> String:
	return "Enemy engine"


func run() -> void:
	_state_capture()
	_state_copy_independence()
	_exposure_geometry()
	_scoring_prefers_screens()
	_enumeration_legality()
	_apply_purity()
	_engine_determinism()
	_weight_resolution()
	_threat_and_incoming()
	_urgency_shape()
	_harm_shape()
	_mana_as_threat()
	_move_enumeration()
	_apply_move_purity()
	_sim_gate()
	_spell_enumeration()
	_ability_enumeration()
	_apply_ability_heal()
	_apply_cast_group_heal()
	_apply_cast_sweeps_dead()
	_apply_ability_fire_bless()
	_board_value_measurement()
	_death_of_own_unit_scores_worse()
	_engine_never_kills_its_own_captain()
	_planning_leaves_the_world_untouched()
	_first_strike_and_delivery()
	_outgoing_mass_shape()
	_behavior_cohort_normalization()
	_mana_optimization_shape()
	_mana_pressure_is_structural()
	_readiness_shape()
	_noop_veto_shape()
	_idle_hand_shape()
	_idle_hand_changes_a_decision()
	_valuation_raw_ignores_the_wound()
	_valuation_persistence_dial()
	_valuation_prices_both_sides()
	_valuation_enhancers_reach_raw()
	_valuation_cache_is_per_pricer()
	_total_value_changes_a_decision()
	_first_strike_is_side_aware()
	_doomed_attacker_projects_less()
	_dodge_expectation_reaches_persistence()
	_crit_expectation_reaches_threat()
	_expectation_honors_determinism_switches()
	_buff_prefers_fresh_over_tapped()
	_king_safety_shape()
	_formation_order_shape()
	_formation_order_silences()
	_arrangement_enumeration()
	_arrangement_feasibility()
	_arrangement_apply_purity()


# ── Formation: value order vs seat safety (the user's spec, restored 2026-07-31) ─────
#
# Pure computation pins — pair concordance between raw worth and v2 exposure. WHICH seat
# the engine then chooses is a behaviour, judged by playtest alone (doctrine at the top
# of this file). Prices are the stock rates' own: queen 7.0 > knight 3.3 > pawn 1.8.
func _formation_order_shape() -> void:
	# The full chain: exposure falls with every screen (pawn 1.0, knight 0.375,
	# queen 0.167) and worth rises the same way — every pair concordant.
	var ideal := _state_with([_enemy("queen", 0, 2), _enemy("knight", 0, 1), _enemy("pawn", 0, 0)])
	check(absf(BoardScoring.formation_order(ideal, 1) - 1.0) < 0.0001,
			"value order matching the safety order is a perfect 1")
	var inverted := _state_with([_enemy("pawn", 0, 2), _enemy("knight", 0, 1), _enemy("queen", 0, 0)])
	check(absf(BoardScoring.formation_order(inverted, 1)) < 0.0001,
			"the exactly inverted seating is 0")
	# The queen tanking at the true front with the right order behind her: her two pairs
	# are misordered, the knight-pawn pair is not — 1/3, graded, never a cliff.
	var queen_front := _state_with([_enemy("queen", 0, 0), _enemy("pawn", 0, 1), _enemy("knight", 0, 2)])
	check(absf(BoardScoring.formation_order(queen_front, 1) - 1.0 / 3.0) < 0.0001,
			"a tanking prize loses exactly its own pairs — the rest still count")
	# THE 20:13 DEFECT, pinned: a cheap unit holding the deepest seat while the prize
	# sits one screen shallower. The prize-vs-cheap pair is misordered (1/3) and the
	# repair — swap their columns — reads strictly better (2/3): the exposure numbers
	# the game already computes are the whole measure.
	var offense := _state_with([_enemy("knight", 0, 0), _enemy("queen", 0, 1), _enemy("pawn", 0, 3)])
	var repaired := _state_with([_enemy("knight", 0, 0), _enemy("pawn", 0, 2), _enemy("queen", 0, 3)])
	check(absf(BoardScoring.formation_order(offense, 1) - 1.0 / 3.0) < 0.0001,
			"a fodder in the best seat over the prize is a misordered pair")
	check(absf(BoardScoring.formation_order(repaired, 1) - 2.0 / 3.0) < 0.0001,
			"…and swapping them is strictly better")
	# A stack is judged through its pairs with the units OUTSIDE it: the prize stacked
	# onto a cheap unit's column ties that pair away, but keeps its pair with the
	# frontman — moving the cheap unit out (prize left sole and deepest) adds the
	# recovered pair as concordant.
	var stacked := _state_with([_enemy("knight", 0, 0), _enemy("pawn", 0, 3), _enemy("queen", 1, 3)])
	var spread := _state_with([_enemy("knight", 0, 0), _enemy("pawn", 0, 2), _enemy("queen", 1, 3)])
	check(BoardScoring.formation_order(spread, 1) > BoardScoring.formation_order(stacked, 1),
			"unstacking the prize from a cheap column-mate reads strictly better")


# The measure's silences: no comparable pairs = no offence = 1.0, never a low score.
func _formation_order_silences() -> void:
	var lone := _state_with([_enemy("queen", 0, 0)])
	check(absf(BoardScoring.formation_order(lone, 1) - 1.0) < 0.0001,
			"a lone unit has no pairs — silent at 1")
	var twins := _state_with([_enemy("pawn", 0, 2), _enemy("pawn", 0, 0)])
	check(absf(BoardScoring.formation_order(twins, 1) - 1.0) < 0.0001,
			"equal worth is no comparison — duplicates carry no opinion")
	# KNOWN SILENCE (on the record in formation_order): a board that is one stack and
	# nothing else has only intra-stack ties — silent. Real boards carry the captain as
	# an outside reference.
	var pure_stack := _state_with([_enemy("queen", 0, 3), _enemy("knight", 1, 3), _enemy("pawn", 2, 3)])
	check(absf(BoardScoring.formation_order(pure_stack, 1) - 1.0) < 0.0001,
			"a board that is ONE stack has no comparable pairs — the known silence")


# ── Arrangements: the two-move reshuffle candidates (user-designed 2026-07-31) ────────
#
# Enumeration and apply plumbing only — whether the engine PICKS an arrangement is
# behaviour, playtest's job. Pins: pair shape, executability filtering, purity.
func _arrangement_enumeration() -> void:
	# Two movable units, otherwise empty board: 3×3 target-column combos each pair, all
	# executable, single-move-equivalent pairs excluded (either unit keeping its column).
	var a := _enemy("pawn", 0, 0)
	var b := _enemy("knight", 1, 1)
	var state := _state_with([a, b])
	var cands := CandidateMoves.arrangements(state, {})
	check_eq(cands.size(), 9, "two movers × 3 foreign columns each = 9 pairs")
	for cand: Dictionary in cands:
		check_eq(String(cand["kind"]), "arrange", "…every candidate is an arrangement")
		check_eq((cand["moves"] as Array).size(), 2, "…of exactly two moves")
		for m: Dictionary in (cand["moves"] as Array):
			check(int(m["col"]) != int(m["from_col"]), "…and neither move keeps its column")
	# A moved unit is out of the pool: no pairs remain for a two-unit board.
	check_eq(CandidateMoves.arrangements(state, {a: true}).size(), 0,
			"a unit that already moved this turn pairs with no one")
	# A building is rooted: same result.
	var rook := _enemy("rook", 2, 2)
	var with_rook := _state_with([a, rook])
	for cand: Dictionary in CandidateMoves.arrangements(with_rook, {}):
		for m: Dictionary in (cand["moves"] as Array):
			check(m["inst"] != rook, "a building never appears in an arrangement")


func _arrangement_feasibility() -> void:
	# Column 3 full; a pair sending TWO outside units into it has no legal order and must
	# not be a candidate — but a pair where one mover LEAVES c3 first (opening the seat)
	# is legal. Executability is decided at enumeration, not discovered at apply.
	var full := [_enemy("pawn", 0, 3), _enemy("pawn", 1, 3), _enemy("pawn", 2, 3)]
	var outsiders := [_enemy("knight", 0, 0), _enemy("bishop", 1, 0)]
	var state := _state_with(full + outsiders)
	var both_in := 0
	var rotation := 0
	for cand: Dictionary in CandidateMoves.arrangements(state, {}):
		var moves: Array = cand["moves"]
		var into_full := 0
		var out_of_full := 0
		for m: Dictionary in moves:
			if int(m["col"]) == 3:
				into_full += 1
			if int(m["from_col"]) == 3:
				out_of_full += 1
		if into_full == 2 and out_of_full == 0:
			both_in += 1
		if into_full == 1 and out_of_full == 1:
			rotation += 1
	check_eq(both_in, 0, "two outsiders into a full column: no legal order, no candidate")
	check(rotation > 0, "one out of the full column, one into the opened seat: legal rotation")


func _arrangement_apply_purity() -> void:
	var a := _enemy("pawn", 0, 0)
	var b := _enemy("knight", 1, 1)
	var state := _state_with([a, b])
	var cand: Dictionary = CandidateMoves.arrangements(state, {})[0]
	var next := CandidateApply.apply(state, cand)
	check(state.unit_at(1, 0, 0) != null and state.unit_at(1, 1, 1) != null,
			"applying an arrangement leaves the source state untouched")
	var m0: Dictionary = (cand["moves"] as Array)[0]
	var m1: Dictionary = (cand["moves"] as Array)[1]
	var u0 := next.unit_at(1, int(m0["row"]), int(m0["col"]))
	var u1 := next.unit_at(1, int(m1["row"]), int(m1["col"]))
	check(u0 != null and u0.source == m0["inst"], "the first mover stands at its target")
	check(u1 != null and u1.source == m1["inst"], "the second mover stands at its target")
	check_eq(next.units(1).size(), 2, "nobody was duplicated or lost in the shuffle")


# The valuation's attack stock is TAP-AWARE (a this-turn instrument): an exhausted unit's
# attack term wears TAP_DELIVERY_FACTOR — this turn its sword is spent; next turn's
# re-valuation restores it. A pure measurement pin: same unit, one flag flipped.
func _buff_prefers_fresh_over_tapped() -> void:
	var fresh := BoardState.UnitState.new()
	fresh.attack = 3
	fresh.strikes = 1
	fresh.health = 2
	fresh.max_health = 2
	var tapped := BoardState.UnitState.new()
	tapped.attack = 3
	tapped.strikes = 1
	tapped.health = 2
	tapped.max_health = 2
	tapped.exhausted = true
	var fresh_raw := BoardScoring.raw_unit_value(fresh)
	var tapped_raw := BoardScoring.raw_unit_value(tapped)
	check(tapped_raw < fresh_raw, "an exhausted unit's raw value discounts its spent swing")
	var expected_gap := 3.0 * (1.0 - BoardScoring.TAP_DELIVERY_FACTOR) \
			* BoardValueConfig.stat_rate("attack")
	check(absf((fresh_raw - tapped_raw) - expected_gap) < 0.0001,
			"…by exactly the attack stock × (1 − TAP_DELIVERY_FACTOR)")


func _enemy(card_id: String, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	inst.owner = 1
	inst.row = r
	inst.col = c
	return inst


func _player(card_id: String, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	inst.row = r
	inst.col = c
	return inst


# A live-shaped grid pair with the given units standing on it.
func _grids(enemy_insts: Array, player_insts: Array = []) -> Array:
	var player_grid: Array = []
	var enemy_grid: Array = []
	for _r in BoardData.ROWS:
		var pr: Array = []
		var er: Array = []
		for _c in BoardData.COLS:
			pr.append(null)
			er.append(null)
		player_grid.append(pr)
		enemy_grid.append(er)
	for inst: CardInstance in enemy_insts:
		enemy_grid[inst.row][inst.col] = inst
	for inst: CardInstance in player_insts:
		player_grid[inst.row][inst.col] = inst
	return [player_grid, enemy_grid]


func _state_capture() -> void:
	var king := _enemy("king", BoardData.ROWS - 1, BoardData.COLS - 1)
	var pawn := _enemy("pawn", 0, 0)
	var grids := _grids([king, pawn])
	var state := BoardState.capture(grids[0], grids[1])

	check_eq(state.units(1).size(), 2, "capture sees both enemy units")
	check_eq(state.units(0).size(), 0, "capture sees an empty player side")
	var cap := state.captain(1)
	check(cap != null and cap.card_id == "king", "captain() finds the king")
	check_eq(cap.row, BoardData.ROWS - 1, "captured unit keeps its row")
	check_eq(cap.col, BoardData.COLS - 1, "captured unit keeps its col")
	check_eq(cap.health, king.current_health, "captured health mirrors the instance")
	check(cap.source == king, "source is the identity token back to the instance")
	check_eq(state.empty_slots(1).size(), BoardData.ROWS * BoardData.COLS - 2,
			"empty_slots excludes occupied cells")


func _state_copy_independence() -> void:
	var king := _enemy("king", BoardData.ROWS - 1, BoardData.COLS - 1)
	var grids := _grids([king])
	var state := BoardState.capture(grids[0], grids[1])
	var copied := state.copy()

	var cap: BoardState.UnitState = copied.captain(1)
	cap.health = 1
	copied.place(BoardState.UnitState.from_instance(_enemy("pawn", 0, 0)), 0, 0)

	check_eq(state.captain(1).health, king.current_health,
			"mutating a copy's unit never reaches the original state")
	check_eq(state.units(1).size(), 1, "placing into a copy never reaches the original grid")
	check_eq(king.current_health, 20, "and never the live CardInstance either")


# ── Exposure (v1: geometry + own-side occupancy) ─────────────────────────────────────

func _state_with(enemy_insts: Array, player_insts: Array = []) -> BoardState:
	var grids := _grids(enemy_insts, player_insts)
	return BoardState.capture(grids[0], grids[1])


# The live-world half of a sim context for direct CandidateApply cast tests: the same
# instances the state was captured from, standing on a CombatWorld (see CandidateApply's
# `sim` parameter — cast/ability candidates copy this world and run the real rules on it).
func _sim_for(enemy_insts: Array, player_insts: Array = [], hand: Array = []) -> Dictionary:
	var grids := _grids(enemy_insts, player_insts)
	var w := CombatWorld.new()
	w.player_grid = grids[0]
	w.enemy_grid = grids[1]
	w.player_side = CombatSide.make(0)
	w.enemy_side = CombatSide.make(1)
	w.enemy_side.hand = hand
	w.modifiers = GameData.current_modifiers
	return {"world": w, "accepted": []}


func _exposure_geometry() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var lone := _state_with([_enemy("king", back, deep)])

	# Exposure v2 (user-designed 2026-07-31): depth is RELATIVE to occupancy. A lone unit
	# is the front line wherever it stands — the empty front column and its own deep seat
	# read identically, because nothing stands between either and the enemy.
	check(absf(BoardScoring.exposure(lone, back, 0) - BoardScoring.exposure(lone, back, deep)) < 0.0001,
			"with nothing in front, the back column is exactly as exposed as the front one")

	var screened := _state_with([_enemy("king", back, deep), _enemy("pawn", back, 1)])
	check(BoardScoring.exposure(screened, back, deep) < BoardScoring.exposure(lone, back, deep),
			"a body in front reduces exposure behind it")

	# Lane-blind screens (v2): nearest-targeting resolves by column depth first, so an
	# off-lane screen in a nearer column intercepts exactly as absolutely as a same-lane
	# one. The v1 1.0/0.5 split modelled nothing in the rules.
	var off_lane := _state_with([_enemy("king", back, deep), _enemy("pawn", 0, 1)])
	check(absf(BoardScoring.exposure(screened, back, deep) - BoardScoring.exposure(off_lane, back, deep)) < 0.0001,
			"a same-lane screen and an off-lane screen cover equally — depth dominates lane")

	var company := _state_with([_enemy("king", back, deep), _enemy("pawn", 0, deep)])
	check(BoardScoring.exposure(company, back, deep) < BoardScoring.exposure(lone, back, deep),
			"same-column company splits attention a little")


func _scoring_prefers_screens() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# The waterfall's two definitional properties (user-stated), pinned where they live:
	# front slots carry strictly more expected damage than back slots in EVERY scenario,
	# and a screen SUBTRACTS from what reaches the ranks behind it.
	var players: Array = [_player("queen", back, 0)]
	var naked := _state_with([_enemy("king", back, deep)], players)
	var screened := _state_with([_enemy("king", back, deep), _enemy("pawn", back, 0)], players)
	var naked_king: BoardState.UnitState = naked.captain(1)
	var screened_king: BoardState.UnitState = screened.captain(1)
	check(BoardScoring.incoming(screened, screened_king) < BoardScoring.incoming(naked, naked_king),
			"stock scoring rates a screened Captain above a naked one")
	var pawn_unit_s: BoardState.UnitState = screened.unit_at(1, back, 0)
	check(BoardScoring.incoming(screened, pawn_unit_s) > BoardScoring.incoming(screened, screened_king),
			"…and the front slot carries strictly more expected damage than the back one")
	# A lone state under stock: TotalValue/damage are behaviors (silent alone), mana reads
	# a turn that spent nothing, the judge has no staged king to guard. What remains are the
	# two criteria that score a lone unit at full marks — READINESS (nothing tapped) and
	# FORMATION (one unit makes no pair, so there is no seating offence to report) — each at
	# its TABLE SHARE, the decision table diluting every peer by its company (see
	# peer_shares). A constant like this cancels out of every ranking; it only shows up
	# here, where a single state is scored on its own.
	var captain_only_scoring := BoardScoring.stock({"default": 0.0})
	var pawn_unit := _enemy("pawn", back, 0)
	var pawn_only := _state_with([pawn_unit])
	var ws: Array = []
	for c: BoardScoring.Criterion in captain_only_scoring.criteria:
		ws.append(c.weight)
	var shares := BoardScoring.peer_shares(ws)
	var full_marks := 0.0
	for i in captain_only_scoring.criteria.size():
		var cid := (captain_only_scoring.criteria[i] as BoardScoring.Criterion).id
		if cid == "readiness" or cid == "formation":
			full_marks += float(shares[i])
	check(absf(captain_only_scoring.score(pawn_only) - full_marks) < 0.0001,
			"with a 0 default weight only readiness' and formation's table shares remain")


# ── Enumeration ──────────────────────────────────────────────────────────────────────

func _spell_inst() -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_ee_spell", "display_name": "S", "cost": 1, "card_type": "spell",
	}))
	inst.owner = 1
	return inst


func _enumeration_legality() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var state := _state_with([_enemy("king", back, deep)])
	var empties := state.empty_slots(1).size()

	var pawn := unit("pawn")
	var queen := unit("queen")
	var king_card := unit("king")
	var pool: Array = [pawn, queen, king_card, _spell_inst()]

	var cands := CandidateMoves.placements(state, pool, 2)
	check_eq(cands.size(), empties, "mana 2 affords only the pawn — one candidate per empty slot")
	for cand: Dictionary in cands:
		check(cand["inst"] == pawn, "…and every candidate places the pawn")

	var rich := CandidateMoves.placements(state, pool, 10)
	check_eq(rich.size(), empties * 2, "mana 10 affords pawn and queen; spells and kings never enumerate")


# ── Apply ────────────────────────────────────────────────────────────────────────────

func _apply_purity() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var state := _state_with([_enemy("king", back, deep)])
	var pawn := unit("pawn")
	var next := CandidateApply.apply(state,
			{"kind": "place", "inst": pawn, "row": back, "col": 0, "cost": 1})

	check_eq(state.units(1).size(), 1, "apply leaves the input state untouched")
	check_eq(next.units(1).size(), 2, "apply's result holds the placement")
	var placed: BoardState.UnitState = next.unit_at(1, back, 0)
	check(placed != null and placed.source == pawn, "the placed unit carries its identity")
	check_eq(placed.owner, 1, "a placed hand card lands enemy-owned")


# ── The engine end to end ────────────────────────────────────────────────────────────

func _seeded_engine() -> EnemyEngine:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	return EnemyEngine.new(rng)


func _engine_determinism() -> void:
	var back := BoardData.ROWS - 1
	var grids := _grids([_enemy("king", back, BoardData.COLS - 1)])
	var hand: Array = [unit("pawn"), unit("knight")]
	var a := _seeded_engine().decide_actions(hand, grids[0], grids[1], 5)
	var b := _seeded_engine().decide_actions(hand, grids[0], grids[1], 5)
	check_eq(a.size(), b.size(), "seeded runs plan the same number of actions")
	for i in a.size():
		var same: bool = a[i]["inst"] == b[i]["inst"] \
				and int(a[i]["row"]) == int(b[i]["row"]) and int(a[i]["col"]) == int(b[i]["col"])
		check(same, "seeded runs pick identical action %d" % i)


# ── Survival weights (role tags → weight table) ──────────────────────────────────────

func _weight_resolution() -> void:
	var weights: Dictionary = BoardScoring.STOCK_SURVIVAL_WEIGHTS
	var fodder := BoardState.UnitState.from_instance(_enemy("fodder_dummy", 0, 0))
	check_eq(BoardScoring.weight_for(fodder, weights), 0.05, "a role tag resolves its table entry")
	var king := BoardState.UnitState.from_instance(_enemy("king", 2, 3))
	check_eq(BoardScoring.weight_for(king, weights), 1.75, "is_king resolves as the captain entry")
	var untagged := BoardState.UnitState.from_instance(_enemy("pawn", 0, 1))
	check_eq(BoardScoring.weight_for(untagged, weights), 0.1, "no role falls to the default entry")
	check_eq(BoardScoring.weight_for(untagged, {"pawn": 7.0}), 7.0, "a card-id entry wins over everything")
	# The per-event override layer (stock() merges encounter entries over the personality's
	# table) currently has NO seated consumer — every survival-weight criterion is parked
	# as a 0..1 contract offender. The resolution is pinned through a hand-seated
	# ProtectionExposure so the mechanism stays whole for their return.
	var merged := BoardScoring.STOCK_SURVIVAL_WEIGHTS.duplicate()
	merged["fodder"] = 0.8
	var pe := BoardScoring.ProtectionExposure.new(merged)
	check_eq(BoardScoring.weight_for(fodder, pe.survival_weights), 0.8,
			"an override rewrites one role's worth, stock fills the rest")
	check_eq(BoardScoring.weight_for(king, pe.survival_weights), 1.75,
			"…without touching un-overridden entries")


# ── The measurement vocabulary: threat mass, incoming, urgency ──────────────────────

func _threat_and_incoming() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# knight fixture: attack 2, strikes 1 ×2 units → threat mass 4.
	var players: Array = [_player("knight", 0, deep), _player("knight", 1, deep)]
	var lone := _state_with([_enemy("king", back, deep)], players)
	check_eq(BoardScoring.threat_mass(lone), 4.0, "threat mass sums player attack × strikes")

	var cap: BoardState.UnitState = lone.captain(1)
	check_eq(BoardScoring.incoming(lone, cap), 4.0,
			"a lone unit absorbs the entire threat mass (the pile-on case)")

	var screened := _state_with(
			[_enemy("king", back, deep), _enemy("pawn", back, 0)], players)
	var s_cap: BoardState.UnitState = screened.captain(1)
	check(BoardScoring.incoming(screened, s_cap) < 4.0,
			"a screen claims its exposure share, so the screened unit's incoming drops")

	var quiet := _state_with([_enemy("king", back, deep)])
	var q_cap: BoardState.UnitState = quiet.captain(1)
	check_eq(BoardScoring.incoming(quiet, q_cap), 0.0, "an empty player board projects no damage")
	check_eq(BoardScoring.urgency(quiet, q_cap), 0.0, "…so nothing is urgent")


func _urgency_shape() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# queen ×2 = 10 threat mass against a lone 2 HP fodder: certain death, clamped at 1.
	var players: Array = [_player("queen", 0, deep), _player("queen", 1, deep)]
	var doomed := _state_with([_enemy("fodder_dummy", 0, 0)], players)
	var fodder: BoardState.UnitState = doomed.units(1)[0]
	check_eq(BoardScoring.urgency(doomed, fodder), 1.0,
			"incoming far past remaining life clamps at certain death")

	var sturdy := _state_with([_enemy("king", back, deep)], [_player("pawn", 0, deep)])
	var cap: BoardState.UnitState = sturdy.captain(1)
	check(BoardScoring.urgency(sturdy, cap) < 0.1,
			"chip damage against a fat health pool barely registers")


# ── Expected harm: sub-lethal damage, weighted by importance ─────────────────────────

func _harm_shape() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# queen ×2 = 10 threat mass, all of it on a lone king (20 max health).
	var players: Array = [_player("queen", 0, deep), _player("queen", 1, deep)]
	var state := _state_with([_enemy("king", back, deep)], players)
	var cap: BoardState.UnitState = state.captain(1)
	cap.shield = 4
	check_eq(BoardScoring.harm(state, cap), 0.3,
			"shield soaks first: (10 incoming − 4 shield) / 20 max health")
	cap.shield = 15
	check_eq(BoardScoring.harm(state, cap), 0.0,
			"a shield bigger than the incoming share means no harm at all")

	# Harm reads MAX health; urgency reads REMAINING life — a wounded unit can be certain
	# to die (urgency 1) while harm still reports the fraction of the whole unit consumed.
	cap.shield = 0
	cap.health = 6
	check_eq(BoardScoring.urgency(state, cap), 1.0, "10 incoming vs 6 remaining: dead")
	# Under the waterfall a body only ever ABSORBS up to its remaining life — the overkill
	# flows past it instead of inflating its own reading — so harm is what the body can
	# still soak: 6 of its 20-point frame, not the thrown 10.
	check_eq(BoardScoring.harm(state, cap), 0.3, "…but harm is what it can still absorb: 6/20")

	# The clamp: incoming far past max health reads as the whole unit, not more.
	var doomed := _state_with([_enemy("fodder_dummy", 0, 0)], players)
	var fodder: BoardState.UnitState = doomed.units(1)[0]
	check_eq(BoardScoring.harm(doomed, fodder), 1.0, "harm clamps at the whole unit")

	# The criterion weights harm by the survival table: the same wound on the same body
	# costs more when the body is the king (1.75) than when it is a tank (0.15).
	var king_state := _state_with([_enemy("captain_dummy", back, deep)], players)
	var tank_state := _state_with([_enemy("tank_dummy", back, deep)], players)
	var king_unit: BoardState.UnitState = king_state.units(1)[0]
	var tank_unit: BoardState.UnitState = tank_state.units(1)[0]
	tank_unit.max_health = king_unit.max_health   # normalize the bodies; only the role differs
	tank_unit.shield = king_unit.shield
	var harm_criterion := BoardScoring.ExpectedHarm.new(BoardScoring.STOCK_SURVIVAL_WEIGHTS)
	check(harm_criterion.score(king_state) < harm_criterion.score(tank_state),
			"the king's 15→6 outranks the tank's 15→6: same harm, weighted by importance")


# ── Open mana counts as threat (1:1) ─────────────────────────────────────────────────

func _mana_as_threat() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var grids := _grids([_enemy("king", back, deep)])
	var state := BoardState.capture(grids[0], grids[1], 5)
	check_eq(BoardScoring.threat_mass(state), 5.0,
			"open player mana is threat at 1:1, even against an empty player board")
	var cap: BoardState.UnitState = state.captain(1)
	check(BoardScoring.urgency(state, cap) > 0.0,
			"…so death risk speaks on a boardless turn one")
	check_eq(state.copy().player_mana, 5, "copies carry the mana snapshot")

	# knight ×1 (attack 2) + 3 open mana: fielded threat and mana threat stack.
	var mixed_grids := _grids([_enemy("king", back, deep)], [_player("knight", 0, deep)])
	var mixed := BoardState.capture(mixed_grids[0], mixed_grids[1], 3)
	check_eq(BoardScoring.threat_mass(mixed), 5.0, "attack × strikes + mana, one pot")


# ── Moves: enumeration + apply ───────────────────────────────────────────────────────

func _move_enumeration() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var king := _enemy("king", back, deep)
	var state := _state_with([king, _enemy("rook", back, 0), _enemy("pawn", 0, 0)])
	var empties := state.empty_slots(1).size()

	var cands := CandidateMoves.moves(state, {})
	check_eq(cands.size(), empties * 2,
			"king and pawn each offer every empty slot; the rooted building offers none")
	var king_moves := cands.filter(func(c: Dictionary) -> bool: return c["inst"] == king)
	check_eq(king_moves.size(), empties, "the king is DELIBERATELY movable (captain-as-tank)")

	var after: Array = CandidateMoves.moves(state, {king: true})
	check_eq(after.size(), empties, "a unit already moved this turn stops offering moves")


func _apply_move_purity() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var king := _enemy("king", back, deep)
	var state := _state_with([king])
	var next := CandidateApply.apply(state, {"kind": "move", "inst": king,
			"from_row": back, "from_col": deep, "row": 0, "col": 0, "cost": 0})

	check(state.unit_at(1, back, deep) != null, "apply leaves the input state untouched")
	check(next.unit_at(1, back, deep) == null, "the result vacates the origin slot")
	var moved: BoardState.UnitState = next.unit_at(1, 0, 0)
	check(moved != null and moved.source == king, "…and the unit stands at the destination")


# ── The sim-support gate: the engine never plays what it cannot evaluate ─────────────

func _sim_gate() -> void:
	check(CandidateApply.can_simulate_cast(AbilityData.get_ability("heal").effects),
			"a manual heal is simulatable")
	check(CandidateApply.can_simulate_cast(AbilityData.get_ability("magic_missile").effects),
			"a manual damage bolt is simulatable")
	check(CandidateApply.can_simulate_cast(CardData.get_card("dummy_group_heal").effects),
			"an all-allies heal is simulatable")
	check(CandidateApply.can_simulate_cast(AbilityData.get_ability("fire_bless").effects),
			"a status-applying cast SIMULATES — the real rules run in sims now (Step 5)")
	check(CandidateApply.can_simulate_cast([Effect.from_dict({
		"trigger": "on_play", "targeting_policy": "manual",
		"attribute": "health", "amount": 2,
		"conditions": [{"attribute": "health", "comparator": "lte", "value": 3}],
	})]), "a condition-gated cast simulates — the real resolver evaluates eligibility")
	check(not CandidateApply.can_simulate_cast([Effect.from_dict({
		"trigger": "on_play", "targeting_policy": "manual",
		"attribute": "health", "amount": -2, "chance": 0.5,
	})]), "a probabilistic cast is STILL refused — the sim would have to guess the roll")
	check(CandidateApply.needs_manual(AbilityData.get_ability("heal").effects),
			"the heal wants a picked target")
	check(not CandidateApply.needs_manual(CardData.get_card("dummy_group_heal").effects),
			"the group heal targets by itself")


# ── Spell / ability enumeration: candidates exist iff the play is legal ──────────────

func _spell_enumeration() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var state := _state_with([_enemy("captain_dummy", back, deep), _enemy("fodder_dummy", back, 0)])
	var group_heal := unit("dummy_group_heal")
	group_heal.owner = 1
	var pool: Array = [group_heal, unit("pawn")]

	check_eq(CandidateMoves.spells(state, pool, 3).size(), 0,
			"mana below the spell's cost enumerates nothing")
	var cands := CandidateMoves.spells(state, pool, 4)
	check_eq(cands.size(), 1, "an area spell is ONE candidate — its targeting is its own")
	if not cands.is_empty():
		check(cands[0]["target"] == null, "…carrying no manual target")
		check_eq(int(cands[0]["cost"]), 4, "…at the card's mana cost")
	check_eq(CandidateMoves.placements(state, [group_heal], 10).size(), 0,
			"a spell card never enumerates as a placement")


func _ability_enumeration() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var support := _enemy("support_dummy", back, 1)
	var state := _state_with([_enemy("captain_dummy", back, deep), support],
			[_player("pawn", 0, deep)])
	var fielded := 3   # two enemies + one player unit — a manual cast tests every one

	var cands := CandidateMoves.abilities(state, 1)
	check_eq(cands.size(), fielded * 2,
			"the support offers heal AND fire_bless at every fielded unit — the status gate fell (Step 5)")
	for cand: Dictionary in cands:
		check((cand["ability"] as AbilityData).id in ["heal", "fire_bless"],
				"…each of its own two abilities")
		check(cand["inst"] == support, "…held by the support")
	check_eq(CandidateMoves.abilities(state, 0).size(), 0, "no mana, no ability candidates")

	var tapped_state := state.copy()
	tapped_state.find(support).exhausted = true
	check_eq(CandidateMoves.abilities(tapped_state, 5).size(), 0,
			"a spent tap closes the ability window")


# ── Apply: casts land on the copy, never the input ───────────────────────────────────

func _apply_ability_heal() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var support := _enemy("support_dummy", back, 1)
	var wounded := _enemy("fodder_dummy", back, 0)
	wounded.current_health = 1
	var roster: Array = [_enemy("captain_dummy", back, deep), support, wounded]
	var state := _state_with(roster)

	var next := CandidateApply.apply(state, {"kind": "ability", "inst": support,
			"ability": AbilityData.get_ability("heal"), "target": wounded, "cost": 1},
			_sim_for(roster))
	check_eq(next.find(wounded).health, 2,
			"the heal restores 2, clamped to the fodder's max of 2")
	check(next.find(support).exhausted, "the sim spends the holder's tap")
	check_eq(state.find(wounded).health, 1, "apply leaves the input state untouched")
	check(not state.find(support).exhausted, "…tap included")
	check_eq(wounded.current_health, 1, "…and never the live CardInstance")


func _apply_cast_group_heal() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var hurt_a := _enemy("tank_dummy", back, 0)
	hurt_a.current_health = 2
	var hurt_b := _enemy("dps_dummy", 0, 1)
	hurt_b.current_health = 1
	var full := _enemy("fodder_dummy", 1, 0)
	var foe := _player("pawn", 0, deep)
	foe.current_health = 1
	var roster: Array = [_enemy("captain_dummy", back, deep), hurt_a, hurt_b, full]
	var state := _state_with(roster, [foe])

	var group_heal := unit("dummy_group_heal")
	group_heal.owner = 1
	var next := CandidateApply.apply(state,
			{"kind": "cast", "inst": group_heal, "target": null, "cost": 4},
			_sim_for(roster, [foe], [group_heal]))
	check_eq(next.find(hurt_a).health, 3, "the area heal reaches every ally")
	check_eq(next.find(hurt_b).health, 2, "…all of them")
	check_eq(next.find(full).health, 2, "a full ally clamps at max")
	check_eq(next.find(foe).health, 1, "an ALL_ALLIES cast never touches the player's side")


func _apply_cast_sweeps_dead() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var burst := _enemy("burst_damage_dummy", back, 0)
	var victim := _player("pawn", 0, deep)
	victim.current_health = 2
	var roster: Array = [_enemy("captain_dummy", back, deep), burst]
	var state := _state_with(roster, [victim])

	var next := CandidateApply.apply(state, {"kind": "ability", "inst": burst,
			"ability": AbilityData.get_ability("magic_missile"), "target": victim, "cost": 3},
			_sim_for(roster, [victim]))
	check(next.find(victim) == null, "a simulated kill removes the unit from the board copy")
	check(state.find(victim) != null, "…only the copy")
	check_eq(victim.current_health, 2, "…and never the live instance")


func _apply_ability_fire_bless() -> void:
	# The refactor's agreed acceptance shape ("Bless by Fire", COMBAT_DECOUPLING_REFACTOR.md
	# criterion 3): a STATUS-APPLYING cast simulates through the real rules — impossible for
	# the deleted SimEffects interpreter. The captured state folds the status's standing
	# +2 attack at read time; the live unit never feels any of it.
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var support := _enemy("support_dummy", back, 1)
	var ally := _enemy("dps_dummy", 0, 2)
	var atk0 := ally.get_attribute("attack")
	var roster: Array = [_enemy("captain_dummy", back, deep), support, ally]
	var state := _state_with(roster)

	var next := CandidateApply.apply(state, {"kind": "ability", "inst": support,
			"ability": AbilityData.get_ability("fire_bless"), "target": ally, "cost": 1},
			_sim_for(roster))
	check_eq(next.find(ally).attack, atk0 + 2,
			"the blessed unit's captured attack folds the status — real statuses run in the sim")
	check(next.find(support).exhausted, "the bless spends the tap")
	check(ally.statuses.is_empty(), "the live unit never gained the status")
	check_eq(ally.get_attribute("attack"), atk0, "…and its live attack never moved")


# ── Board value: the net worth of the battlefield (replaced presence) ────────────────

func _board_value_measurement() -> void:
	# Pin the exchange rates so the arithmetic below is deterministic whatever the
	# authored data/board_value.json says.
	BoardValueConfig.set_config({
		"stat_rates": {"attack": 1.0, "health": 1.0, "missing_health": 0.1,
				"shield": 2.0, "speed": 0.5},
		"ability_default": 2.0, "ability_values": {"heal": 3.0},
		"triggered_default": 1.5, "live_default": 1.5,
	})

	var fodder := BoardState.UnitState.from_instance(_enemy("fodder_dummy", 0, 0))
	var expected := float(fodder.attack * fodder.strikes) + float(fodder.health) \
			+ float(fodder.max_health - fodder.health) * 0.1 \
			+ float(fodder.shield) * 2.0 + float(fodder.speed) * 0.5 \
			+ float(fodder.ability_ids.size()) * 2.0 \
			+ float(fodder.triggered_effects + fodder.live_effects) * 1.5
	check(absf(BoardScoring.unit_value(fodder) - expected) < 0.0001,
			"a unit's value is its stats at the authored exchange rates + its kit")

	# The authored biases, isolated one axis at a time.
	var base := BoardScoring.unit_value(fodder)
	var shielded := fodder.copy()
	shielded.shield += 1
	check(absf(BoardScoring.unit_value(shielded) - base - 2.0) < 0.0001,
			"a shield point is worth double (it regenerates)")
	var quick := fodder.copy()
	quick.speed += 2
	check(absf(BoardScoring.unit_value(quick) - base - 1.0) < 0.0001,
			"a speed point is worth half")
	# Health a unit still holds counts full; health it has SPENT still counts, but only
	# 0.1 — so damage costs 0.9 per point and healing earns that back.
	var wounded := fodder.copy()
	wounded.health -= 1
	check(absf(base - BoardScoring.unit_value(wounded) - 0.9) < 0.0001,
			"spending a point of health costs 0.9 — the point, less what the scar still counts")
	# The user's own case: a bigger frame is worth something even carrying a wound, so a
	# damaged 4/5 outvalues an untouched 4/4. Both terms positive is what guarantees it.
	var big_frame := fodder.copy()
	big_frame.max_health += 1
	check(BoardScoring.unit_value(big_frame) > BoardScoring.unit_value(fodder),
			"a 4/5 with one wound outvalues a whole 4/4 — max health is part of the worth")
	var supp := BoardState.UnitState.from_instance(_enemy("support_dummy", 0, 1))
	check_eq(supp.ability_ids.size(), 2, "the support carries two abilities (fixture sanity)")
	var kitless := supp.copy()
	kitless.ability_ids = []
	check(absf(BoardScoring.unit_value(supp) - BoardScoring.unit_value(kitless) - 5.0) < 0.0001,
			"abilities price by id when authored (heal 3.0) and by default otherwise (2.0)")

	# The net: own units add, player units subtract — hurting the player IS gaining.
	var even := _state_with([_enemy("fodder_dummy", 0, 0)], [_player("fodder_dummy", 0, 3)])
	check(absf(BoardScoring.board_value(even)) < 0.0001,
			"mirrored boards cancel to zero")
	var behind := _state_with([_enemy("fodder_dummy", 0, 0)],
			[_player("fodder_dummy", 0, 3), _player("knight", 1, 3)])
	check(BoardScoring.board_value(behind) < 0.0, "a richer player board reads negative")

	# The min-max anchoring: worst option 0, best 1, signed measures welcome.
	var criterion := BoardScoring.BoardValue.new()
	var norm := criterion.normalized([-4.0, 6.0, 1.0])
	check_eq(float(norm[0]), 0.0, "the pick's worst option anchors at 0")
	check_eq(float(norm[1]), 1.0, "…its best at 1")
	check_eq(float(norm[2]), 0.5, "…and the rest sit at their fraction of the span")
	var flat := criterion.normalized([3.0, 3.0])
	check_eq(float(flat[0]), 0.0, "a flat cohort goes silent — nothing to prefer")

	BoardValueConfig.set_config({})   # release the pin — next read reloads from disk


# ── Losing a unit must never READ as relief ─────────────────────────────────────────
#
# The hole this pins: every negative criterion sums over LIVING units, so a unit that
# dies during a simulation silently leaves the sum and its risk term evaporates — making
# "destroy your own valuable unit" score as an improvement. Death must be the worst
# outcome for a unit, not the absence of one.

func _death_of_own_unit_scores_worse() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var scoring := BoardScoring.stock()
	var players: Array = [_player("knight", 0, deep)]

	# Isolating the death accounting: the SAME board either way — one reached by killing
	# the dps, one where it was never there. Identical geometry, identical survivors (the
	# caster genuinely stands on the board in the real-rules path, so it stands in BOTH
	# states); the only difference is that one of them cost a unit to get to. That must
	# score worse, and nothing but the graveyard term can say so.
	var doomed := _enemy("dps_dummy", 0, 0)
	doomed.current_health = 1
	var burst := _enemy("burst_damage_dummy", 0, 1)
	var roster: Array = [_enemy("captain_dummy", back, deep), doomed, burst]
	var before := _state_with(roster, players)
	var missile := {"kind": "ability", "inst": burst,
			"ability": AbilityData.get_ability("magic_missile"), "target": doomed, "cost": 3}
	var killed := CandidateApply.apply(before, missile, _sim_for(roster, players))
	var never_there := _state_with(
			[_enemy("captain_dummy", back, deep), _enemy("burst_damage_dummy", 0, 1)], players)

	check(killed.find(doomed) == null, "the bolt did kill the dps (fixture sanity)")
	check_eq(killed.graveyard.size(), 1, "…and the corpse is recorded")
	# Since the valuation system, the loss speaks through TOTAL VALUE — a behavior, so the
	# three states are compared as one cohort (which is exactly how the engine sees every
	# pick): the killed unit's worth simply leaves the sum.
	var totals := scoring.score_pick([before, killed, never_there])
	check(float(totals[1]) < float(totals[2]),
			"reaching a board by KILLING an own unit scores worse than the same board without it")
	check(float(totals[1]) < float(totals[0]),
			"…and worse than leaving the dying unit alive")
	check_eq(BoardState.capture(_grids([])[0], _grids([])[1]).graveyard.size(), 0,
			"a freshly captured board starts with an empty graveyard")

	# A dead PLAYER unit is not a loss to mourn — it stops contributing threat, which the
	# threat mass already rewards. It must never be charged to the enemy's own risk.
	var victim := _player("knight", 0, deep)
	victim.current_health = 1
	var burst2 := _enemy("burst_damage_dummy", 0, 1)
	var foe_roster: Array = [_enemy("captain_dummy", back, deep), burst2]
	var with_foe := _state_with(foe_roster, [victim])
	var foe_killed := CandidateApply.apply(with_foe,
			{"kind": "ability", "inst": burst2,
			 "ability": AbilityData.get_ability("magic_missile"), "target": victim, "cost": 3},
			_sim_for(foe_roster, [victim]))
	var foe_totals := scoring.score_pick([with_foe, foe_killed])
	check(float(foe_totals[1]) > float(foe_totals[0]),
			"killing a PLAYER unit is still an improvement — their negative worth leaves the total")


func _engine_never_kills_its_own_captain() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# A wounded Captain and a burst unit holding a 3-damage bolt: the bolt can finish it.
	# Killing its own king removes the board's biggest risk term (weight 1.75) and costs no
	# presence (the captain's mana cost is 0) — so an unguarded scorer rates suicide as the
	# best play available. Losing the Captain IS losing the fight; no score may buy it.
	var captain := _enemy("captain_dummy", back, deep)
	captain.current_health = 2
	captain.current_shield = 0
	var burst := _enemy("burst_damage_dummy", back, 0)
	var enemies: Array = [captain, burst, _enemy("fodder_dummy", 0, 0)]
	var players: Array = [_player("queen", 0, deep), _player("queen", 1, deep)]
	var grids := _grids(enemies, players)

	var engine := _seeded_engine()
	var actions := engine.decide_actions([], grids[0], grids[1], 3)
	var bolts_own: Array = actions.filter(func(a: Dictionary) -> bool:
		if int(a["type"]) != EnemyEngine.Action.GENERATE:
			return false
		var t: CardInstance = a.get("target", null)
		return t != null and t.owner == 1)
	check_eq(bolts_own.size(), 0, "the CPU never aims a damage ability at its own units")

	# …and the criterion itself must say so, not just this board's arithmetic.
	var scoring := BoardScoring.stock()
	var state := BoardState.capture(grids[0], grids[1])
	var suicide := CandidateApply.apply(state, {"kind": "ability", "inst": burst,
			"ability": AbilityData.get_ability("magic_missile"), "target": captain, "cost": 3},
			_sim_for(enemies, players))
	var pair := scoring.score_pick([state, suicide])
	check(float(pair[1]) < float(pair[0]),
			"killing its own Captain scores worse than doing nothing at all")


# ── Damage output: the aggression measurement (EVAL_CRITERIA_BRIEF.md eval 2) ─────────

func _unit_by_id(state: BoardState, side: int, card_id: String) -> BoardState.UnitState:
	for u: BoardState.UnitState in state.units(side):
		if u.card_id == card_id:
			return u
	return null


func _first_strike_and_delivery() -> void:
	var deep := BoardData.COLS - 1
	# No player attackers: nothing can pre-empt a strike — delivery is certain.
	var quiet := _state_with([_enemy("dps_dummy", 0, 0)])
	var lone: BoardState.UnitState = quiet.units(1)[0]
	check_eq(BoardScoring.first_strike_share(quiet, lone), 1.0,
			"an empty player board pre-empts nothing")
	check_eq(BoardScoring.delivery(quiet, lone), 1.0, "…so delivery is certain")

	# Speed decides how much of the round is insured: slower player threat cannot land
	# before the unit's first strike; faster threat leaves delivery hanging on survival.
	var players: Array = [_player("queen", 0, deep), _player("queen", 1, deep)]
	var pressed := _state_with([_enemy("dps_dummy", 0, 0)], players)
	var fragile: BoardState.UnitState = pressed.units(1)[0]
	for foe: BoardState.UnitState in pressed.units(0):
		foe.speed = fragile.speed - 1
	check_eq(BoardScoring.first_strike_share(pressed, fragile), 1.0,
			"all player threat slower → the whole first strike is insured")
	check_eq(BoardScoring.delivery(pressed, fragile), 1.0,
			"…so even a doomed body still delivers its round")
	for foe: BoardState.UnitState in pressed.units(0):
		foe.speed = fragile.speed + 1
	check_eq(BoardScoring.first_strike_share(pressed, fragile), 0.0,
			"all player threat faster → nothing is insured")
	check_eq(BoardScoring.delivery(pressed, fragile),
			1.0 - BoardScoring.urgency(pressed, fragile),
			"…and delivery falls back to pure survival")


func _outgoing_mass_shape() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# Under no pressure the mass is the pure stat projection — threat_mass, mirrored.
	var calm := _state_with([_enemy("dps_dummy", 0, 0), _enemy("knight", 1, 0)])
	var expected := 0.0
	for u: BoardState.UnitState in calm.units(1):
		expected += float(u.attack * u.strikes)
	check_eq(BoardScoring.outgoing_mass(calm), expected,
			"under no pressure the mass is exactly Σ attack × strikes")

	# A buff moves the measure — the initiative's whole point.
	var buffed := calm.copy()
	buffed.units(1)[0].attack += 2
	check(BoardScoring.outgoing_mass(buffed) > BoardScoring.outgoing_mass(calm),
			"+2 attack raises the outgoing mass")

	# A spent tap is a spent swing: the tapped unit's contribution collapses to the hard
	# cap, so tapping reads as a damage detractor and "is this worth my tap" is priced
	# into every ability candidate.
	var fresh: BoardState.UnitState = calm.units(1)[0]
	var tapped := calm.copy()
	tapped.units(1)[0].exhausted = true
	var tap_loss := BoardScoring.outgoing_mass(calm) - BoardScoring.outgoing_mass(tapped)
	var expected_loss := float(fresh.attack * fresh.strikes) \
			* (1.0 - BoardScoring.TAP_DELIVERY_FACTOR)
	check(absf(tap_loss - expected_loss) < 0.0001,
			"a tapped unit keeps only the hard-capped sliver of its output")
	var tapped_buffed := tapped.copy()
	tapped_buffed.units(1)[0].attack += 2
	check(BoardScoring.outgoing_mass(buffed) - BoardScoring.outgoing_mass(calm) >
			BoardScoring.outgoing_mass(tapped_buffed) - BoardScoring.outgoing_mass(tapped),
			"…so the same buff is worth more on a fresh body than on a tapped one")

	# The user's founding example: the same stat is worth more on a body that will live
	# to use it. A screened striker out-delivers the identical striker standing naked.
	var players: Array = [_player("queen", 0, deep)]
	var screened := _state_with(
			[_enemy("dps_dummy", back, deep), _enemy("tank_dummy", back, 0)], players)
	var naked := _state_with([_enemy("dps_dummy", back, deep)], players)
	var s_dps := _unit_by_id(screened, 1, "dps_dummy")
	var n_dps := _unit_by_id(naked, 1, "dps_dummy")
	for state: BoardState in [screened, naked]:
		for foe: BoardState.UnitState in state.units(0):
			foe.speed = 99   # player strikes first everywhere — delivery is pure survival
	check(BoardScoring.delivery(screened, s_dps) > BoardScoring.delivery(naked, n_dps),
			"a screened striker converts more of its attack stat than a naked one")


func _behavior_cohort_normalization() -> void:
	# The score_pick contract: goals score per-state as always; a behavior normalizes by
	# the cohort max — the pick's fullest expression scores exactly 1, the rest their
	# fraction, and a lone state reads nothing at all.
	var a := _state_with([_enemy("dps_dummy", 0, 0)])
	var b := _state_with([_enemy("dps_dummy", 0, 0), _enemy("knight", 1, 0)])
	var scoring := BoardScoring.new()
	var behavior := BoardScoring.DamageOutput.new()
	behavior.weight = 1.0
	scoring.criteria.append(behavior)
	var totals := scoring.score_pick([a, b])
	check_eq(float(totals[1]), 1.0, "the cohort's best expression scores exactly 1")
	check_eq(float(totals[0]),
			BoardScoring.outgoing_mass(a) / BoardScoring.outgoing_mass(b),
			"…and the rest their fraction of it")
	check_eq(scoring.score(a), 0.0,
			"a behavior is silent on a lone state — expression is relative")
	var zeros := scoring.score_pick([_state_with([]), _state_with([])])
	check_eq(float(zeros[0]), 0.0,
			"a cohort with no expression anywhere goes silent instead of dividing by zero")


# ── Mana optimization: spent > spendable > stranded (the fielding pressure) ──────────

func _mana_optimization_shape() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var state := _state_with([_enemy("captain_dummy", back, deep)])
	check_eq(BoardScoring.mana_optimization(state), 0.0,
			"no budget stamped → a constant, invisible to ranking")

	state.enemy_mana_total = 5
	state.enemy_mana_left = 5
	state.hand_costs = [2, 3, 4]
	check_eq(BoardScoring.mana_optimization(state), 0.0,
			"a choice that spends nothing scores 0, however healthy the budget — "
			+ "declining is what every placement must beat")

	# Every case below shares one formula: what this choice's line consumes ÷ the most
	# any line could have consumed from the pre-choice position (mana_capacity_before).
	#
	# The user's equivalence (2026-07-30): spending everything and leaving a fully usable
	# reserve are EQUALLY good. Only waste is punished.
	var spent_all := state.copy()
	spent_all.mana_spent_step = 5
	spent_all.enemy_mana_left = 0
	spent_all.hand_costs = [4]
	spent_all.mana_capacity_before = 5
	check_eq(BoardScoring.mana_optimization(spent_all), 1.0, "spending the whole pool scores 1")
	var kept_usable := state.copy()
	kept_usable.mana_spent_step = 2
	kept_usable.enemy_mana_left = 3
	kept_usable.hand_costs = [1, 2]
	kept_usable.mana_capacity_before = 5
	check_eq(BoardScoring.mana_optimization(kept_usable), 1.0,
			"…and so does a spend leaving a remainder the hand can still fully consume")

	# Abundance is not waste: mana no remaining option could ever absorb was never
	# spendable by ANY line, so the counterfactual yardstick ignores it. This is what
	# lets the LAST card in hand score 1 instead of tying with declining.
	var abundant := state.copy()
	abundant.mana_spent_step = 2
	abundant.enemy_mana_left = 7
	abundant.hand_costs = [2]
	abundant.mana_capacity_before = 4   # the 2 just played + the 2 still held
	check_eq(BoardScoring.mana_optimization(abundant), 1.0,
			"leftover mana no remaining option could ever use is abundance, not waste")
	var emptied := state.copy()
	emptied.mana_spent_step = 2
	emptied.enemy_mana_left = 5
	emptied.hand_costs = []
	emptied.mana_capacity_before = 2   # that last card was all there was to spend on
	check_eq(BoardScoring.mana_optimization(emptied), 1.0,
			"…so playing the last card scores full marks, not zero")

	# Squandering: 5 mana with a 1-cost and a 5-cost in hand — taking the 1 consumes one
	# fifth of what the pool could have absorbed (the user's "spend 1 and leave the rest
	# unusable" case, now measured against what was actually achievable).
	var squandered := state.copy()
	squandered.mana_spent_step = 1
	squandered.enemy_mana_left = 4
	squandered.hand_costs = [5]
	squandered.mana_capacity_before = 5
	check(absf(BoardScoring.mana_optimization(squandered) - 0.2) < 0.0001,
			"spending 1 where 5 was available scores near the floor")
	check(BoardScoring.mana_optimization(squandered)
			< BoardScoring.mana_optimization(abundant),
			"…and real waste is strictly worse than untouchable leftover")

	# The combo-blindness cure (the brief's own example): with 5 mana and options 2/3/4,
	# playing the 4 strands 1; playing the 3 keeps the 2 consumable.
	var played4 := state.copy()
	played4.mana_spent_step = 4
	played4.enemy_mana_left = 1
	played4.hand_costs = [2, 3]
	played4.mana_capacity_before = 5
	var played3 := state.copy()
	played3.mana_spent_step = 3
	played3.enemy_mana_left = 2
	played3.hand_costs = [2, 4]
	played3.mana_capacity_before = 5
	check_eq(BoardScoring.spend_capacity(played4), 0, "1 left vs cheapest option 2 → stranded")
	check_eq(BoardScoring.spend_capacity(played3), 2, "2 left → the 2-cost still fits")
	check_eq(BoardScoring.mana_optimization(played3), 1.0, "playing the 3 keeps a perfect line")
	check(BoardScoring.mana_optimization(played4) < 1.0,
			"…while playing the 4 strands a point and scores below it")

	# ── THE INVARIANT ────────────────────────────────────────────────────────────────
	# SPENDING MANA ALWAYS BEATS SPENDING NONE. Never let this break again: it has been
	# broken three separate times by three different formulas (a cumulative measure that
	# maxed out on doing nothing; a literal 0 floor that tied with declining; an absolute
	# stranded-mana reading that scored 0 whenever an unaffordable card sat in hand). Each
	# time the visible symptom was the CPU withholding units it could clearly play, and
	# each time the user had to report it again. A tie is a failure here — the engine
	# requires STRICT improvement, so equal-to-declining means never played.
	var decline_at := func(left: int, costs: Array, capacity: int) -> float:
		var s := state.copy()
		s.mana_spent_step = 0
		s.enemy_mana_left = left
		s.hand_costs = costs
		s.mana_capacity_before = capacity
		return BoardScoring.mana_optimization(s)
	var spend_at := func(cost: int, left: int, costs: Array, capacity: int) -> float:
		var s := state.copy()
		s.mana_spent_step = cost
		s.enemy_mana_left = left
		s.hand_costs = costs
		s.mana_capacity_before = capacity
		return BoardScoring.mana_optimization(s)
	# left, remaining hand, capacity, and the cost just paid — including every shape that
	# has broken before: a lingering unaffordable card, an emptied hand, a stranding pick,
	# and a 1-of-many-mana spend.
	var shapes: Array = [
		[1, 9, [], 1], [1, 9, [20], 1], [1, 4, [5], 5], [1, 0, [], 1],
		[2, 5, [], 2], [2, 3, [1, 2], 5], [4, 1, [2, 3], 5], [5, 0, [4], 5],
		[1, 7, [2, 8], 3], [3, 2, [2, 4], 5],
	]
	for shape: Array in shapes:
		var cost := int(shape[0])
		var left := int(shape[1])
		var costs: Array = shape[2]
		var capacity := int(shape[3])
		var spent_score: float = spend_at.call(cost, left, costs, capacity)
		var idle_score: float = decline_at.call(left, costs, capacity)
		check(spent_score > idle_score,
				"spending %d (left %d, hand %s, capacity %d) must beat declining — got %.3f vs %.3f"
				% [cost, left, str(costs), capacity, spent_score, idle_score])

	# Ability mana counts as a spendable option only while the holder's tap is available.
	var supported := _state_with([_enemy("support_dummy", 0, 0)])
	supported.enemy_mana_total = 1
	supported.enemy_mana_left = 1
	supported.mana_spent_step = 1
	check_eq(BoardScoring.spend_capacity(supported), 1,
			"an untapped unit's ability mana is spendable")
	supported.units(1)[0].exhausted = true
	check_eq(BoardScoring.spend_capacity(supported), 0,
			"…and stops counting once the tap is spent")


# ── The structural guarantee behind the fielding pressure ────────────────────────────
#
# "Spending mana beats spending none" must not be something that merely happens to fall
# out of the arithmetic — it broke three times that way. The engine derives the mana
# yardstick from the candidate cohort, which makes the guarantee structural: in ANY pick
# that offers an affordable play, the best candidate scores EXACTLY 1.0 on mana while
# declining scores exactly 0.0. So the pressure to play is always the criterion's full
# weight, never an epsilon that a risk term can swallow.
#
# The shapes below include the ones that produced the live bug: a hand holding a card the
# CPU cannot afford, and a hand holding a spell no candidate can play at all (no legal
# target / unsimulatable) — both of which used to inflate the yardstick out of reach.

func _mana_pressure_is_structural() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var unplayable := CardInstance.from_data(CardData.build_from_dict({
		"id": "_ee_unplayable", "display_name": "U", "cost": 3, "card_type": "spell",
		"effects": [{"trigger": "on_play", "targeting_policy": "manual",
			"attribute": "health", "amount": -2, "chance": 0.5}],
	}))   # probabilistic → refused by the sim gate, so it never becomes a candidate
	unplayable.owner = 1

	var cases: Array = [
		{"mana": 4, "hand": ["fodder_dummy", "dps_dummy"], "extra": null},
		{"mana": 4, "hand": ["fodder_dummy", "dps_dummy"], "extra": "queen"},
		{"mana": 3, "hand": ["fodder_dummy"], "extra": "unplayable"},
		{"mana": 7, "hand": ["dps_dummy", "tank_dummy"], "extra": "unplayable"},
		{"mana": 1, "hand": ["fodder_dummy"], "extra": "queen"},
	]
	for case: Dictionary in cases:
		var enemies: Array = [_enemy("captain_dummy", back, deep)]
		var players: Array = [_player("knight", 0, deep)]
		var grids := _grids(enemies, players)
		var hand: Array = []
		for id: Variant in case["hand"]:
			var h := unit(String(id))
			h.owner = 1
			hand.append(h)
		if case["extra"] == "queen":
			var q := unit("queen")
			q.owner = 1
			hand.append(q)
		elif case["extra"] == "unplayable":
			hand.append(unplayable)

		var state := BoardState.capture(grids[0], grids[1], 0)
		state.enemy_mana_total = int(case["mana"])
		state.enemy_mana_left = int(case["mana"])
		for h2: CardInstance in hand:
			state.hand_costs.append(int(h2.get_attribute("cost")))
		var sim := _sim_for(enemies, players, hand)
		var cands := CandidateMoves.placements(state, hand, int(case["mana"]))
		cands.append_array(CandidateMoves.spells(state, hand, int(case["mana"])))
		cands.append_array(CandidateMoves.abilities(state, int(case["mana"])))
		var label := "mana %d, hand %s + %s" % [int(case["mana"]), str(case["hand"]),
				str(case["extra"])]
		check(not cands.is_empty(), "%s — some play is affordable (fixture sanity)" % label)

		# Mirror the engine's own bookkeeping, then read the mana criterion directly.
		state.mana_spent_step = 0
		var cohort: Array = [state]
		var achieved: Array = []
		for cand: Dictionary in cands:
			var next := CandidateApply.apply(state, cand, sim)
			EnemyEngine._note_spend(next, cand)
			cohort.append(next)
			achieved.append(int(cand["cost"]) + BoardScoring.spend_capacity(next))
		var capacity := 0
		for a: Variant in achieved:
			capacity = maxi(capacity, int(a))
		for s: BoardState in cohort:
			s.mana_capacity_before = capacity

		var best := 0.0
		for i in cands.size():
			best = maxf(best, BoardScoring.mana_optimization(cohort[i + 1]))
		check(absf(best - 1.0) < 0.0001,
				"%s — the best available play earns the FULL mana score, got %.4f"
				% [label, best])
		check_eq(BoardScoring.mana_optimization(cohort[0]), 0.0,
				"%s — and declining earns none of it" % label)


# ── Readiness: a tap is a second currency, and it has to cost something ──────────────

func _readiness_shape() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var support := _enemy("support_dummy", back, 1)
	var state := _state_with([_enemy("captain_dummy", back, deep), support,
			_enemy("dps_dummy", 0, 2)])
	check_eq(BoardScoring.readiness(state), 1.0, "an untouched army is fully ready")

	var tapped := state.copy()
	tapped.find(support).exhausted = true
	check(BoardScoring.readiness(tapped) < 1.0, "a spent tap costs readiness")

	# The tap's price is what it FORFEITS — the unit's swing plus every ability the tap
	# closes — so silencing the two-ability support costs more than silencing a plain
	# body with the same attack.
	var plain := _state_with([_enemy("captain_dummy", back, deep),
			_enemy("fodder_dummy", back, 1), _enemy("dps_dummy", 0, 2)])
	var plain_tapped := plain.copy()
	plain_tapped.units(1).filter(func(u: BoardState.UnitState) -> bool:
		return u.card_id == "fodder_dummy")[0].exhausted = true
	check(BoardScoring.readiness(tapped) < BoardScoring.readiness(plain_tapped),
			"tapping a unit that holds abilities costs more than tapping a bare body")

	# Proportional: the same tap silences more of a small army than a large one.
	var lone := _state_with([_enemy("support_dummy", back, 1)])
	var lone_tapped := lone.copy()
	lone_tapped.units(1)[0].exhausted = true
	check(BoardScoring.readiness(lone_tapped) < BoardScoring.readiness(tapped),
			"tapping your only unit spends far more of the army's agency")

	var idle := _state_with([_enemy("captain_dummy", back, deep)])
	check_eq(BoardScoring.readiness(idle), 1.0,
			"a captain with no abilities still reads ready (its swing is all it has)")

	# The tap is never billed for the ability it BOUGHT — only for the swing and the
	# other abilities it closed (the user's exact model). A one-ability unit that taps
	# therefore forfeits its attack and nothing more.
	var burst := BoardState.UnitState.from_instance(_enemy("burst_damage_dummy", 0, 0))
	burst.exhausted = true
	check(absf(BoardScoring.tap_forfeit(burst)
			- float(burst.attack * burst.strikes) * BoardValueConfig.stat_rate("attack")) < 0.0001,
			"tapping a one-ability unit costs its swing, not the ability it just used")
	var supp_unit := BoardState.UnitState.from_instance(_enemy("support_dummy", 0, 1))
	supp_unit.exhausted = true
	check(BoardScoring.tap_forfeit(supp_unit) > BoardScoring.tap_forfeit(burst),
			"…while a two-ability unit also forfeits the one it did NOT use")


# ── The no-op legality rule: an effect that changes nothing is not a candidate ────────

func _noop_veto_shape() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var support := _enemy("support_dummy", back, 1)
	var full := _enemy("fodder_dummy", back, 0)
	var roster: Array = [_enemy("captain_dummy", back, deep), support, full]
	var state := _state_with(roster)
	var futile := CandidateApply.apply(state, {"kind": "ability", "inst": support,
			"ability": AbilityData.get_ability("heal"), "target": full, "cost": 1},
			_sim_for(roster))
	check(EnemyEngine._effect_changed_nothing(state, futile),
			"a heal at full health changes nothing — the tap and mana are costs, not outcomes")

	var hurt := _enemy("fodder_dummy", back, 0)
	hurt.current_health = 1
	var support2 := _enemy("support_dummy", back, 1)
	var roster2: Array = [_enemy("captain_dummy", back, deep), support2, hurt]
	var state2 := _state_with(roster2)
	var real := CandidateApply.apply(state2, {"kind": "ability", "inst": support2,
			"ability": AbilityData.get_ability("heal"), "target": hurt, "cost": 1},
			_sim_for(roster2))
	check(not EnemyEngine._effect_changed_nothing(state2, real),
			"a heal that actually restores health is a real play")


# ── Idle hand: a body it could field is never left in hand ───────────────────────────
#
# The blunt criterion (user mandate 2026-07-30, after the withholding bug kept coming back
# through the mana pool): count the placeable units in hand the CPU could put down right
# now, charge one full weight each. These are the properties that make it uncheatable.

func _idle_hand_shape() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var state := _state_with([_enemy("captain_dummy", back, deep)])
	check_eq(BoardScoring.idle_hand(state), 0.0,
			"nothing stamped → the criterion is a constant, invisible to ranking")

	state.hand_unit_costs = [1, 2]
	state.hand_budget_before = 2
	state.enemy_mana_left = 2
	check_eq(BoardScoring.idle_hand(state), 2.0,
			"two fieldable bodies in hand are charged twice — the count is never diluted")

	var lean := state.copy()
	lean.hand_budget_before = 1
	check_eq(BoardScoring.idle_hand(lean), 1.0,
			"a card it cannot afford is unplayable, not withheld")

	# THE WAIVER (user 2026-07-30): spending mana settles the charge, whatever the mana was
	# spent on. The criterion forbids IDLENESS while holding a body — it must never argue
	# against another paid play, which is what made its first cut stop the support from
	# healing a dying ally (a heal spends mana but empties no hand).
	var paid := state.copy()
	paid.mana_spent_step = 1
	check_eq(BoardScoring.idle_hand(paid), 0.0,
			"a choice that spends mana is never charged, even with bodies still in hand")

	# THE DODGE THIS CLOSES: affordability is judged against the pool the PICK started with,
	# never the mana left. Read against the mana left, any play that drains the pool would
	# make the held body look unaffordable and the charge would vanish — casting a spell
	# would excuse keeping a unit in hand, which is the withholding bug wearing yet another
	# costume. Spending the mana elsewhere must keep the charge; only fielding pays it off.
	var spent_elsewhere := state.copy()
	spent_elsewhere.enemy_mana_left = 0
	check_eq(BoardScoring.idle_hand(spent_elsewhere), 2.0,
			"spending the mana on something else does NOT excuse the withheld bodies")
	var fielded := state.copy()
	fielded.hand_unit_costs = [2]
	check_eq(BoardScoring.idle_hand(fielded), 1.0,
			"…and playing one of them is what actually clears its charge")

	# Nowhere to stand is not withholding.
	var packed_insts: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			packed_insts.append(_enemy("fodder_dummy", r, c))
	var packed := _state_with(packed_insts)
	packed.hand_unit_costs = [1]
	packed.hand_budget_before = 5
	check_eq(BoardScoring.idle_hand(packed), 0.0, "a full board cannot field anything")

	# Spells and kings never enter the charge — neither is a placeable body. Read through
	# the engine's own stamping, so the filter is pinned where it lives.
	var grids := _grids([_enemy("captain_dummy", back, deep)])
	var spell := unit("dummy_group_heal")
	spell.owner = 1
	var engine := _seeded_engine()
	engine.decide_actions([spell], grids[0], grids[1], 4)
	var stamped := BoardState.capture(grids[0], grids[1])
	stamped.hand_unit_costs = []
	check_eq(BoardScoring.idle_hand(stamped), 0.0,
			"a hand of spells charges nothing — there is no body being withheld")

	# PARKED (0..1 contract): idle_hand scores in plain counts, which the decision table
	# cannot seat — so it holds NO seat in the stock scorer. The measure above stays whole
	# for its later inspection; the fielding pressure it backed up is carried by the mana
	# criterion (pinned by _engine_never_withholds_a_playable_unit and THE INVARIANT).
	var idle_criteria: Array = BoardScoring.stock().criteria.filter(
			func(c: BoardScoring.Criterion) -> bool: return c.id == "idle_hand")
	check_eq(idle_criteria.size(), 0, "the parked criterion holds no seat in the stock character")
	var charged := state.copy()
	check(BoardScoring.IdleHand.new().score(charged) < 0.0,
			"…but the mechanism still scores withholding as a loss when hand-seated")


# PARKED (0..1 contract): idle_hand and protection — the two sides of the old A/B — are
# both contract offenders and hold no seat, so the anti-decoration A/B that lived here is
# retired with them. What this pins instead: the parking itself, in both directions — the
# stock scorer seats NEITHER offender, and neither can sneak back in through a personality
# that lists one. ⚠ When either is unparked (re-expressed on 0..1), an anti-decoration A/B
# in the old shape (same pick scored with and without the criterion, on a knife-edge board)
# must return with it — a green suite is not evidence a criterion bites.
func _idle_hand_changes_a_decision() -> void:
	var stock_ids: Array = []
	for c: BoardScoring.Criterion in BoardScoring.stock().criteria:
		stock_ids.append(c.id)
	check(not stock_ids.has("idle_hand"), "parked idle_hand holds no stock seat")
	check(not stock_ids.has("protection"), "parked protection holds no stock seat")
	check(not stock_ids.has("death_risk") and not stock_ids.has("harm"),
			"the parked pre-valuation trio holds no stock seat")
	# A personality that asks for a parked quirk does not get it seated either — parked
	# means unseated for everyone, pending inspection, not opt-in.
	var wants_parked := EnemyPersonality.from_dict({"id": "_p",
			"quirks": {"death_risk": 1.0, "harm": 0.5}})
	var seated: Array = []
	for c: BoardScoring.Criterion in BoardScoring.stock({}, wants_parked).criteria:
		seated.append(c.id)
	check(not seated.has("death_risk") and not seated.has("harm"),
			"a personality cannot seat a parked offender")


# ── The refactor's closing promise: planning is a pure read ──────────────────────────

func _planning_leaves_the_world_untouched() -> void:
	# Acceptance criterion 5 (COMBAT_DECOUPLING_REFACTOR.md): a whole planned CPU turn —
	# real-rules casts included — writes NOTHING to the live world. Every simulation runs
	# on copies; the plan is the only output.
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var support := _enemy("support_dummy", back, 1)
	var wounded := _enemy("dps_dummy", 0, 2)
	wounded.current_health = 1
	var enemies: Array = [_enemy("captain_dummy", back, deep), support, wounded]
	var players: Array = [_player("knight", 0, deep), _player("knight", 1, deep)]
	var grids := _grids(enemies, players)
	var group_heal := unit("dummy_group_heal")
	group_heal.owner = 1

	var w := CombatWorld.new()
	w.player_grid = grids[0]
	w.enemy_grid = grids[1]
	w.player_side = CombatSide.make(0)
	w.enemy_side = CombatSide.make(1)
	w.enemy_side.hand = [group_heal]
	w.modifiers = GameData.current_modifiers

	var engine := _seeded_engine()
	engine.weight_overrides = {"dps": 0.6}
	engine.world = w
	var actions := engine.decide_actions([group_heal], grids[0], grids[1], 4)

	check(not actions.is_empty(), "the plan found work to do (fixture sanity)")
	check_eq(wounded.current_health, 1, "planning never healed the live unit")
	check(not support.attack_exhausted, "planning never spent a live tap")
	check(support.statuses.is_empty() and wounded.statuses.is_empty(),
			"no live unit gained a status")
	check_eq(w.enemy_side.hand.size(), 1, "the live hand kept its spell")
	var live_row: Array = w.enemy_grid[0]
	check(live_row[2] == wounded, "the live grid never moved")


# ── The valuation pass (user-designed 2026-07-30) ────────────────────────────────────
#
# Before ANY eval runs, every unit on BOTH sides is priced: RAW worth (what it IS —
# stats, kit, role, enhancers; current health irrelevant) discounted by PERSISTENCE
# (how likely it survives the turn) through the ONE dial, persistence_weight. The stamp
# is canon — the TotalValue criterion reads it, and so must any future value eval.

func _valuation_raw_ignores_the_wound() -> void:
	var fresh := BoardState.UnitState.from_instance(_enemy("dps_dummy", 0, 0))
	var hurt_inst := _enemy("dps_dummy", 0, 1)
	hurt_inst.current_health = 1
	var hurt := BoardState.UnitState.from_instance(hurt_inst)
	check_eq(BoardScoring.raw_unit_value(fresh), BoardScoring.raw_unit_value(hurt),
			"a wounded unit is worth the same RAW as a fresh one — the wound is persistence's business")
	# …and raw prices the frame: a bigger max pool is worth more, wound or no wound.
	var big := fresh.copy()
	big.max_health += 2
	check(BoardScoring.raw_unit_value(big) > BoardScoring.raw_unit_value(fresh),
			"max health is part of what the unit IS")


func _valuation_persistence_dial() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# A doomed fodder under two queens: urgency clamps to certain death, persistence 0.
	var players: Array = [_player("queen", 0, deep), _player("queen", 1, deep)]
	var state := _state_with([_enemy("fodder_dummy", 0, 0)], players)
	var fodder: BoardState.UnitState = state.units(1)[0]

	BoardValueConfig.set_config({"persistence_weight": 0.0})
	BoardScoring.run_valuation(state)
	check_eq(fodder.persistence, 0.0, "the fodder is certainly dead (fixture sanity)")
	check_eq(fodder.value, fodder.raw_value,
			"dial at 0: fragility is ignored — a dying unit is still its whole raw worth")

	BoardValueConfig.set_config({"persistence_weight": 1.0})
	state.valued = false
	BoardScoring.run_valuation(state)
	check_eq(fodder.value, 0.0,
			"dial at 1: a certainly-dead unit is worth nothing at all")

	BoardValueConfig.set_config({"persistence_weight": 0.5})
	state.valued = false
	BoardScoring.run_valuation(state)
	check(absf(fodder.value - fodder.raw_value * 0.5) < 0.0001,
			"between the poles the discount interpolates: value = raw × lerp(1, persistence, dial)")

	# The safe captain keeps ~everything at any dial: persistence ≈ 1 means no discount.
	var quiet := _state_with([_enemy("captain_dummy", back, deep)])
	BoardValueConfig.set_config({"persistence_weight": 1.0})
	BoardScoring.run_valuation(quiet)
	var cap: BoardState.UnitState = quiet.captain(1)
	check_eq(cap.persistence, 1.0, "no threat, full persistence")
	check_eq(cap.value, cap.raw_value, "…and no discount even at full dial")
	BoardValueConfig.set_config({})


func _valuation_prices_both_sides() -> void:
	var deep := BoardData.COLS - 1
	# Mirrored boards cancel; a richer player board reads negative — sides oppose.
	var even := _state_with([_enemy("fodder_dummy", 0, 0)], [_player("fodder_dummy", 0, 0)])
	BoardScoring.run_valuation(even)
	check(absf(even.value_total) < 0.0001, "mirrored boards cancel to zero")
	for side in 2:
		for u: BoardState.UnitState in even.units(side):
			check(u.value > 0.0, "every unit on side %d carries a stamped value" % side)

	var behind := _state_with([_enemy("fodder_dummy", 0, 0)],
			[_player("fodder_dummy", 0, 0), _player("knight", 1, deep)])
	BoardScoring.run_valuation(behind)
	check(behind.value_total < 0.0, "a richer player board reads negative")

	# Player persistence is measured against the CPU's fielded mass — hurting their
	# survivors' odds (or removing them) raises the total, which is the "reduce enemy
	# value" half of the initiative folded into the same number.
	var pressed := _state_with(
			[_enemy("queen", 0, 0), _enemy("queen", 1, 0)], [_player("knight", 0, deep)])
	BoardScoring.run_valuation(pressed)
	var foe: BoardState.UnitState = pressed.units(0)[0]
	check(foe.persistence < 1.0, "a player unit under CPU mass reads endangered")


func _valuation_enhancers_reach_raw() -> void:
	var fodder := BoardState.UnitState.from_instance(_enemy("fodder_dummy", 0, 0))
	var king := BoardState.UnitState.from_instance(_enemy("king", 0, 1))
	var dps := BoardState.UnitState.from_instance(_enemy("dps_dummy", 0, 2))
	var fodder_plain := BoardScoring.raw_unit_value(fodder)
	var king_plain := BoardScoring.raw_unit_value(king)
	var dps_plain := BoardScoring.raw_unit_value(dps)

	# ROLE TAGS ARE PARKED OUT OF THE EVAL (user call 2026-07-31: "roles unfold naturally
	# from stats in this system" — protecting high-value targets is a future eval's job).
	# An authored role_values table still parses but must move NOTHING: this pins the
	# parking, so a stray config can't quietly reintroduce role pricing.
	BoardValueConfig.set_config({"role_values": {"fodder": 3.0, "captain": 5.0},
			"unit_values": {"dps_dummy": 7.0}})
	check(absf(BoardScoring.raw_unit_value(fodder) - fodder_plain) < 0.0001,
			"a role bonus no longer reaches raw value — role tags are out of the eval")
	check(absf(BoardScoring.raw_unit_value(king) - king_plain) < 0.0001,
			"…and the king's captain entry is equally inert")
	check(absf(BoardScoring.raw_unit_value(dps) - dps_plain - 7.0) < 0.0001,
			"a per-card enhancer prices one specific unit — NOT a role tag, still live")

	# A personality layers its own entries per key over the global table (unit prices
	# only — its role_values are parked with the rest).
	var p := EnemyPersonality.from_dict({"id": "_pricey",
			"value_rates": {"role_values": {"fodder": 9.0}, "unit_values": {"dps_dummy": 1.0}}})
	check(absf(BoardScoring.raw_unit_value(fodder, p) - fodder_plain) < 0.0001,
			"a personality's role bonus is parked like the global one")
	check(absf(BoardScoring.raw_unit_value(dps, p) - dps_plain - 1.0) < 0.0001,
			"…and its per-card price replaces the global one")
	BoardValueConfig.set_config({})


# THE LANDMINE THIS PINS (caught live during the build): the valuation stamp is cached on
# the state, but it is only canon for the PRICER that produced it. A state first scored by
# one fight's scorer and then read by another's — different per-fight price list — must be
# re-valued, or one fight's prices leak into the other's reading.
func _valuation_cache_is_per_pricer() -> void:
	var state := _state_with([_enemy("rook", 1, 0)])
	var plain := BoardScoring.stock()
	plain.score(state)
	var unpriced := state.value_total
	var priced_scorer := BoardScoring.stock({}, EnemyPersonality.from_dict({"id": "_rich",
			"value_rates": {"unit_values": {"rook": 10.0}}}))
	priced_scorer.score(state)
	check(absf(state.value_total - unpriced - 10.0) < 0.0001,
			"a scorer with its own price list re-values a state another scorer already stamped")
	plain.score(state)
	check(absf(state.value_total - unpriced) < 0.0001,
			"…and the way back re-values again — the stamp remembers WHO priced it")


# The anti-decoration A/B (the standing rule: a green suite is not evidence a criterion
# bites — score the same pick with the weight zeroed and demand a DIFFERENT decision).
# Deliberately direction-free (tests validate computation, behaviors belong to the
# playtest): what is pinned is that the criterion's weight REACHES the decision, not
# which choice is right.
func _total_value_changes_a_decision() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var dying_tower := _enemy("rook", 1, 0)
	dying_tower.current_health = 1
	dying_tower.current_shield = 0
	var support := _enemy("support_dummy", back, 1)
	var enemies: Array = [_enemy("captain_dummy", back, deep), support, dying_tower]
	# Fast for the same reason as the arbitration fixture: the knight's pressure must
	# fully deliver, or the expected-damage model rightly stops calling the tower dying.
	var knight := _player("knight", 0, deep)
	knight.modifiers["speed"] = 7
	var players: Array = [knight]
	var fodder := unit("fodder_dummy")
	fodder.owner = 1
	var grids := _grids(enemies, players)
	var state := BoardState.capture(grids[0], grids[1])
	state.enemy_mana_total = 1
	state.enemy_mana_left = 1
	state.hand_costs = [1]
	state.hand_unit_costs = [1]
	state.mana_spent_step = 0
	var sim := _sim_for(enemies, players, [fodder])
	var heal := {"kind": "ability", "inst": support,
			"ability": AbilityData.get_ability("heal"), "target": dying_tower, "cost": 1}
	var place := {"kind": "place", "inst": fodder, "row": back, "col": 0, "cost": 1}
	var cohort: Array = [state]
	for cand: Dictionary in [heal, place]:
		var next := CandidateApply.apply(state, cand, sim)
		EnemyEngine._note_spend(next, cand)
		next.mana_capacity_before = 1
		next.hand_budget_before = 1
		cohort.append(next)
	state.mana_capacity_before = 1
	state.hand_budget_before = 1

	var pricer := EnemyPersonality.from_dict({"id": "_tower_fight",
			"value_rates": {"unit_values": {"rook": 10.0}}})
	var with_it := BoardScoring.stock({}, pricer)
	var without := BoardScoring.stock({}, pricer)
	for c: BoardScoring.Criterion in without.criteria:
		if c.id == "total_value":
			c.weight = 0.0
	var verdict := func(scoring: BoardScoring) -> String:
		var totals := scoring.score_pick(cohort)
		return "heal" if float(totals[1]) > float(totals[2]) else "place"
	check(verdict.call(with_it) != verdict.call(without),
			"zeroing total value's weight flips the pick — the criterion reaches the decision")


# ── The expected-damage model (user-designed 2026-07-31) ─────────────────────────────
#
# The valuation pass's second-pass threat: raw stat mass corrected toward what will
# actually land — attackers discounted by delivery (a unit that dies before it swings
# throws less), raised by crit expectation, defenders crediting their own dodge. Not a
# new value channel: a correction to incoming(), flowing into persistence and everything
# downstream. The pairwise speed-edge terms are measured against one aggregate reference
# speed per side (no-pairing doctrine, design 17b).

func _first_strike_is_side_aware() -> void:
	# The player unit's insurance is judged against the CPU army — the mirror of the CPU
	# reading that always worked. One fast CPU unit, one slow: a mid-speed player unit is
	# insured against exactly the slow one's mass.
	var state := _state_with(
			[_enemy("dps_dummy", 0, 0), _enemy("tank_dummy", 1, 0)],
			[_player("knight", 0, 0)])
	var foe: BoardState.UnitState = state.units(0)[0]
	foe.speed = 2   # dps_dummy 3 is faster, tank_dummy 1 is slower
	var tank_mass := 0.0
	var total_mass := 0.0
	for u: BoardState.UnitState in state.units(1):
		total_mass += float(u.attack * u.strikes)
		if u.card_id == "tank_dummy":
			tank_mass += float(u.attack * u.strikes)
	check_eq(BoardScoring.first_strike_share(state, foe), tank_mass / total_mass,
			"a player unit's first-strike share reads the CPU army, not its own side")


func _doomed_attacker_projects_less() -> void:
	# Two boards, identical except the lone player attacker's plight: safe in the back
	# vs standing doomed under the CPU's whole mass with everything outspeeding it. The
	# defender the attacker threatens must read SAFER on the doomed board — damage a
	# dead unit never lands isn't damage.
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var safe := _state_with(
			[_enemy("fodder_dummy", 0, 0)], [_player("queen", back, deep)])
	# The CPU queens stand DEEP so the fodder is the waterfall's first stop — front-most,
	# it receives the naive mass; whether that mass is real is exactly what the refined
	# pass discounts (position never gates attacking, so the deep queens still doom the
	# player's attacker).
	var doomed := _state_with(
			[_enemy("queen", 1, deep), _enemy("queen", 2, deep), _enemy("fodder_dummy", 0, 0)],
			[_player("queen", 0, 0)])
	for s: BoardState in [safe, doomed]:
		for u: BoardState.UnitState in s.units(0):
			u.speed = 1   # slower than everything — no first-strike insurance
		for u: BoardState.UnitState in s.units(1):
			u.speed = 3
	BoardScoring.run_valuation(safe)
	BoardScoring.run_valuation(doomed)
	var safe_atk: BoardState.UnitState = safe.units(0)[0]
	var doomed_atk: BoardState.UnitState = doomed.units(0)[0]
	check(BoardScoring.delivery(safe, safe_atk) > BoardScoring.delivery(doomed, doomed_atk),
			"the doomed attacker converts less of its stat (fixture sanity)")
	var naive_fodder := _unit_by_id(doomed, 1, "fodder_dummy")
	check(naive_fodder.persistence > BoardScoring.persistence(doomed, naive_fodder),
			"the stamped persistence outreads the naive one: the doomed attacker's mass is discounted")


func _dodge_expectation_reaches_persistence() -> void:
	var prev := Resolver.dodge_enabled
	Resolver.dodge_enabled = true
	Resolver.set_dodge_tuning({
		"fixed_pct": 0.0, "per_speed_pct": 5.0, "per_speed_diff_pct": 0.0, "max_pct": 75.0,
	})
	# Same slot, same body, different speed: the faster unit dodges more of its incoming
	# share, so it stamps higher persistence — speed is damage-reduction information now.
	# The attacker outspeeds BOTH variants, so its own first-strike share (which reads
	# defender speeds too) is identical across the boards — dodge is the only variable.
	var slow := _state_with([_enemy("tank_dummy", 0, 0)], [_player("queen", 0, 0)])
	var fast := _state_with([_enemy("tank_dummy", 0, 0)], [_player("queen", 0, 0)])
	slow.units(0)[0].speed = 9
	fast.units(0)[0].speed = 9
	slow.units(1)[0].speed = 1
	fast.units(1)[0].speed = 8
	BoardScoring.run_valuation(slow)
	BoardScoring.run_valuation(fast)
	check(fast.units(1)[0].persistence > slow.units(1)[0].persistence,
			"a faster unit expects to dodge more of its incoming share")

	# The flat effect-granted bonus reaches the model too (a relic-built dodger is not
	# invisible), and a building never dodges, whatever its numbers say.
	var plain := _state_with([_enemy("tank_dummy", 0, 0)], [_player("queen", 0, 0)])
	var blessed := _state_with([_enemy("tank_dummy", 0, 0)], [_player("queen", 0, 0)])
	blessed.units(1)[0].dodge_bonus = 30
	BoardScoring.run_valuation(plain)
	BoardScoring.run_valuation(blessed)
	check(blessed.units(1)[0].persistence > plain.units(1)[0].persistence,
			"dodge_bonus raises the expectation like the Resolver folds it into the roll")
	var rooted := BoardState.UnitState.new()
	rooted.is_building = true
	rooted.speed = 8
	check_eq(BoardScoring.dodge_expect(rooted, 0.0), 0.0,
			"a building never dodges — hard 0 before any tuning term")
	Resolver.set_dodge_tuning({})
	Resolver.dodge_enabled = prev


func _crit_expectation_reaches_threat() -> void:
	var prev := Resolver.crit_enabled
	Resolver.crit_enabled = true
	Resolver.set_crit_tuning({
		"fixed_pct": 0.0, "per_speed_pct": 5.0, "per_speed_diff_pct": 0.0,
		"max_pct": 90.0, "multiplier": 2.0, "multiplier_max": 5.0,
	})
	# Same attack stat, different attacker speed: the faster player unit's expected
	# crits raise the mass bearing down, so the CPU unit under it stamps LOWER
	# persistence — the fight really does run hotter under a fast army. The defender is
	# slower than BOTH variants, so the attacker's first-strike share (which reads
	# defender speeds) is identical across the boards — crit is the only variable.
	var calm := _state_with([_enemy("tank_dummy", 0, 0)], [_player("queen", 0, 0)])
	var hot := _state_with([_enemy("tank_dummy", 0, 0)], [_player("queen", 0, 0)])
	calm.units(1)[0].speed = 0
	hot.units(1)[0].speed = 0
	calm.units(0)[0].speed = 1
	hot.units(0)[0].speed = 8
	BoardScoring.run_valuation(calm)
	BoardScoring.run_valuation(hot)
	check(hot.units(1)[0].persistence < calm.units(1)[0].persistence,
			"a faster attacker's expected crits raise the expected incoming")

	# The CPU's own aggression measure rides the same expectation: outgoing mass grows
	# with the crit factor the fight will actually roll.
	var army := _state_with([_enemy("dps_dummy", 0, 0)], [_player("queen", 0, 0)])
	army.units(0)[0].speed = 1   # slower than the dps — its strike is insured, delivery 1
	var with_crit := BoardScoring.outgoing_mass(army)
	Resolver.crit_enabled = false
	var without_crit := BoardScoring.outgoing_mass(army)
	check(with_crit > without_crit, "crit expectation raises the outgoing damage mass")
	Resolver.set_crit_tuning({})
	Resolver.crit_enabled = prev


func _expectation_honors_determinism_switches() -> void:
	# The runner keeps dodge/crit OFF (the deterministic harness): the model's factors
	# must read exactly neutral — the scorer never believes in a rule the fight will not
	# roll, and every pre-model assertion in this suite stays byte-identical.
	check(not Resolver.dodge_enabled and not Resolver.crit_enabled,
			"harness precondition: the switches are off outside the flipped blocks")
	var u := BoardState.UnitState.new()
	u.speed = 9
	u.dodge_bonus = 50
	u.crit_chance_bonus = 50
	check_eq(BoardScoring.dodge_expect(u, 0.0), 0.0, "disabled dodge expects nothing")
	check_eq(BoardScoring.crit_expect(u, 0.0), 1.0, "disabled crit is a neutral factor")


# ── King safety: the win-condition JUDGE ──────────────────────────────────────────────

# The judge seat: full authority, no weight, contributes by OBJECTION (0..1) read off the
# king's stamped endangerment — no tags, no tables. Its categorical objection to the
# king's death IS the engine veto (which _engine_never_kills_its_own_captain pins).
func _king_safety_shape() -> void:
	var deep := BoardData.COLS - 1
	var judge := BoardScoring.KingSafety.new()

	# Same threat, two postures: the judge reads the actual danger on the king, so a
	# covered back-corner king draws less objection than one standing alone up front.
	# ONE queen — enough to push the exposed posture past the panic floor while the
	# covered one stays under it; heavier threat would saturate both at GRADED_MAX and
	# the ordering would vanish into the ceiling.
	var exposed := _state_with(
			[_enemy("captain_dummy", 1, 0), _enemy("fodder_dummy", 0, deep)],
			[_player("queen", 0, deep)])
	var covered := _state_with(
			[_enemy("captain_dummy", 1, deep), _enemy("fodder_dummy", 1, 0)],
			[_player("queen", 0, deep)])
	check(judge.objection(covered) < judge.objection(exposed),
			"a covered king under threat draws less objection than an exposed one")
	check(not judge.categorical(exposed),
			"danger short of death is never categorical — a living king still negotiates")

	# Threat-scaled by construction: with nothing bearing down, posture is free — this is
	# what leaves the approved moderate-threat advance alive while lethal threat drives
	# the full retreat.
	var calm := _state_with([_enemy("captain_dummy", 1, 0)], [])
	check_eq(judge.objection(calm), 0.0, "an unthreatened king draws no objection")

	# A king that DIED draws the categorical objection (the veto, by arithmetic) — while
	# a board that never staged a king has nothing to protect and stays silent, so
	# kingless test fixtures carry no constant discount.
	var dead := _state_with([_enemy("captain_dummy", 0, 0)], [])
	var fallen: BoardState.UnitState = dead.units(1)[0]
	dead.grid_of(1)[0][0] = null
	dead.graveyard.append(fallen)
	check_eq(judge.objection(dead), 1.0, "a dead king draws total objection")
	check(judge.categorical(dead), "…and it is categorical — the veto is this judge")
	var kingless := _state_with([_enemy("fodder_dummy", 0, 0)], [])
	check_eq(judge.objection(kingless), 0.0, "a board that never staged a king is silent")
	check(not judge.categorical(kingless), "…and never vetoed")

	# The living-king objection is CAPPED below 1 (GRADED_MAX): a cornered king chooses
	# among bad options instead of vetoing them all — only death itself is absolute.
	var mob: Array = []
	for r in BoardData.ROWS:
		mob.append(_player("queen", r, deep))
	var doomed := _state_with([_enemy("fodder_dummy", 0, 0), _enemy("captain_dummy", 0, 1)], mob)
	BoardScoring.run_valuation(doomed)
	check(judge.objection(doomed) <= BoardScoring.KingSafety.GRADED_MAX + 0.0001,
			"a living king's objection never reaches the categorical ceiling")
