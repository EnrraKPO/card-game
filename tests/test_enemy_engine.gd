extends TestCase

# The enemy engine's decision pipeline (ENCOUNTER_ENGINE_DESIGN.md Part 5): plain-data
# board state, candidate enumeration, apply, exposure scoring, selection. Grows a section
# per pipeline part as the slice widens.


func suite_name() -> String:
	return "Enemy engine"


func run() -> void:
	_state_capture()
	_state_copy_independence()
	_exposure_geometry()
	_scoring_prefers_screens()
	_enumeration_legality()
	_apply_purity()
	_engine_screens_captain()
	_engine_determinism()


func _enemy(card_id: String, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	inst.owner = 1
	inst.row = r
	inst.col = c
	return inst


# A live-shaped grid pair with the given enemy units standing on it.
func _grids(enemy_insts: Array) -> Array:
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

func _state_with(enemy_insts: Array) -> BoardState:
	var grids := _grids(enemy_insts)
	return BoardState.capture(grids[0], grids[1])


func _exposure_geometry() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var lone := _state_with([_enemy("king", back, deep)])

	check(BoardScoring.exposure(lone, back, 0) > BoardScoring.exposure(lone, back, deep),
			"the front column is more exposed than the back column")

	var screened := _state_with([_enemy("king", back, deep), _enemy("pawn", back, 1)])
	check(BoardScoring.exposure(screened, back, deep) < BoardScoring.exposure(lone, back, deep),
			"a body in front reduces exposure behind it")

	var off_lane := _state_with([_enemy("king", back, deep), _enemy("pawn", 0, 1)])
	check(BoardScoring.exposure(screened, back, deep) < BoardScoring.exposure(off_lane, back, deep),
			"a same-lane screen covers harder than an off-lane one")

	var company := _state_with([_enemy("king", back, deep), _enemy("pawn", 0, deep)])
	check(BoardScoring.exposure(company, back, deep) < BoardScoring.exposure(lone, back, deep),
			"same-column company splits attention a little")


func _scoring_prefers_screens() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var scoring := BoardScoring.stock()
	var lone := _state_with([_enemy("king", back, deep)])
	var screened := _state_with([_enemy("king", back, deep), _enemy("pawn", back, 0)])
	check(scoring.score(screened) > scoring.score(lone),
			"stock scoring rates a screened Captain above a naked one")
	var pawn_only := _state_with([_enemy("pawn", back, 0)])
	check_eq(scoring.score(pawn_only), 0.0,
			"day-one weights ignore non-captain units (default weight 0)")


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


func _engine_screens_captain() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	var grids := _grids([_enemy("king", back, deep)])
	var hand: Array = [unit("pawn"), unit("pawn")]

	var actions := _seeded_engine().decide_actions(hand, grids[0], grids[1], 10)
	check_eq(actions.size(), 2, "both affordable units get placed")
	for action: Dictionary in actions:
		check_eq(int(action["type"]), EnemyEngine.Action.PLACE, "day one emits placements")
		check_eq(int(action["row"]), back, "each placement screens in the Captain's lane")
		check(int(action["col"]) < deep, "…in front of the Captain, not beside it")


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
