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
	_weight_resolution()
	_threat_and_incoming()
	_urgency_shape()
	_move_enumeration()
	_apply_move_purity()
	_scoring_triages_dying_unit()
	_engine_king_tanks()
	_engine_king_retreats_fully()


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
	# The deliverable-1 configuration, pinned explicitly via an override: with untagged
	# units weighted 0, a captain-less board scores flat.
	var captain_only_scoring := BoardScoring.stock({"default": 0.0})
	var pawn_only := _state_with([_enemy("pawn", back, 0)])
	check_eq(captain_only_scoring.score(pawn_only), 0.0,
			"a default-weight override of 0 makes untagged units invisible to scoring")


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

	# The deliverable-1 observable under its original weight table (captain-only), pinned via
	# override — under stock weights untagged pawns are worth something themselves, so their
	# own safety legitimately competes with pure captain-screening.
	var engine := _seeded_engine()
	engine.weight_overrides = {"default": 0.0}
	var actions := engine.decide_actions(hand, grids[0], grids[1], 10)
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


# ── Survival weights (role tags → weight table) ──────────────────────────────────────

func _weight_resolution() -> void:
	var weights: Dictionary = BoardScoring.STOCK_SURVIVAL_WEIGHTS
	var fodder := BoardState.UnitState.from_instance(_enemy("fodder_dummy", 0, 0))
	check_eq(BoardScoring.weight_for(fodder, weights), 0.05, "a role tag resolves its table entry")
	var king := BoardState.UnitState.from_instance(_enemy("king", 2, 3))
	check_eq(BoardScoring.weight_for(king, weights), 2.5, "is_king resolves as the captain entry")
	var untagged := BoardState.UnitState.from_instance(_enemy("pawn", 0, 1))
	check_eq(BoardScoring.weight_for(untagged, weights), 0.1, "no role falls to the default entry")
	check_eq(BoardScoring.weight_for(untagged, {"pawn": 7.0}), 7.0, "a card-id entry wins over everything")
	# The per-event override layer: stock() merges encounter entries over the stock table.
	var overridden := BoardScoring.stock({"fodder": 0.8})
	var dr: BoardScoring.DeathRisk = overridden.criteria[0]
	check_eq(BoardScoring.weight_for(fodder, dr.survival_weights), 0.8,
			"an encounter override rewrites one role's worth, stock fills the rest")
	check_eq(BoardScoring.weight_for(king, dr.survival_weights), 2.5,
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


# ── The deliverable-2 observable: triage beats marginal captain cover ────────────────

func _scoring_triages_dying_unit() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# The Captain sits screened and comfortable; a wounded support (weight 0.5) stands
	# exposed in the far lane; modest real threat is on the player's board. One cheap
	# fodder body is worth more screening the dying support than doubling captain cover.
	var scoring := BoardScoring.stock()
	var players: Array = [_player("knight", 0, deep)]

	var support_a := _enemy("support_dummy", 0, 1)
	support_a.current_health = 2
	var screens_support := _state_with([
		_enemy("captain_dummy", back, deep), _enemy("pawn", back, 0), support_a,
		_enemy("fodder_dummy", 0, 0),
	], players)

	var support_b := _enemy("support_dummy", 0, 1)
	support_b.current_health = 2
	var pads_captain := _state_with([
		_enemy("captain_dummy", back, deep), _enemy("pawn", back, 0), support_b,
		_enemy("fodder_dummy", back, 1),
	], players)

	check(scoring.score(screens_support) > scoring.score(pads_captain),
			"a dying support outweighs marginal cover for a comfortable Captain")


# ── Captain-as-tank: the king steps forward when its body is the best screen ─────────

func _engine_king_tanks() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# The BOLD-captain event character, pinned via override (captain 1.0 — stock is the
	# protective 2.5): precious fodders crowd every column except the front, serious threat
	# bears down, only front-line slots are open, and nobody's 2 HP body soaks damage as
	# well as the Captain's fat pool. Decision 15 in reverse.
	var captain := _enemy("captain_dummy", back, deep)
	var enemies: Array = [captain]
	for r in BoardData.ROWS:
		enemies.append(_enemy("fodder_dummy", r, 1))
		enemies.append(_enemy("fodder_dummy", r, 2))
	enemies.append(_enemy("fodder_dummy", 0, deep))
	enemies.append(_enemy("fodder_dummy", 1, deep))
	var players: Array = [_player("queen", 0, deep), _player("queen", 1, deep)]
	var grids := _grids(enemies, players)

	var engine := _seeded_engine()
	engine.weight_overrides = {"fodder": 0.6, "captain": 1.0}
	var actions := engine.decide_actions([], grids[0], grids[1], 0)

	var king_moves: Array = actions.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.MOVE and a["inst"] == captain)
	check_eq(king_moves.size(), 1, "the bold Captain steps out exactly once")
	if not king_moves.is_empty():
		check_eq(int(king_moves[0]["col"]), 0, "…to the front line, tanking for its fodders")


# ── Protective commitment (stock): the threatened king claims the back column ────────

func _engine_king_retreats_fully() -> void:
	var deep := BoardData.COLS - 1
	# The observed defect this pins: a mid-column king under real threat used to send a
	# FODDER to the free back seat (or wander forward to soak share) because at captain
	# weight 1.0 its health pool read as the cheapest sponge. Stock 2.5 commits: the king
	# itself takes the deep slot. Mid-column is also exactly the leaper's landing zone.
	var captain := _enemy("captain_dummy", 1, 2)
	var enemies: Array = [
		captain,
		_enemy("fodder_dummy", 1, 0),
		_enemy("fodder_dummy", 0, deep),
		_enemy("fodder_dummy", 2, deep),
	]
	var players: Array = [_player("queen", 0, deep), _player("queen", 1, deep)]
	var grids := _grids(enemies, players)

	var engine := _seeded_engine()
	engine.weight_overrides = {"fodder": 0.5}
	var actions := engine.decide_actions([], grids[0], grids[1], 0)

	var king_moves: Array = actions.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.MOVE and a["inst"] == captain)
	check_eq(king_moves.size(), 1, "the threatened king repositions itself")
	if not king_moves.is_empty():
		check_eq(int(king_moves[0]["col"]), deep,
				"…all the way to the back column — no half-hearted mid-column stop")
