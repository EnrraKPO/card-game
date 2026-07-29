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
	_harm_shape()
	_mana_as_threat()
	_move_enumeration()
	_apply_move_purity()
	_scoring_triages_dying_unit()
	_engine_king_tanks()
	_engine_king_retreats_fully()
	_engine_king_shares_moderate_threat()
	_sim_gate()
	_spell_enumeration()
	_ability_enumeration()
	_apply_ability_heal()
	_apply_cast_group_heal()
	_apply_cast_sweeps_dead()
	_presence_measurement()
	_engine_heals_wounded_ally()
	_engine_casts_group_heal()
	_engine_place_vs_heal_arbitration()
	_death_of_own_unit_scores_worse()
	_engine_never_kills_its_own_captain()


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
	# units weighted 0, the RISK criteria go silent for a captain-less board — what
	# remains is exactly the unit's board-presence term (presence deliberately does NOT
	# ride the survival-weight table: how much we fear losing a unit and how much we
	# want it fielded are different dials).
	var captain_only_scoring := BoardScoring.stock({"default": 0.0})
	var pawn_unit := _enemy("pawn", back, 0)
	var pawn_only := _state_with([pawn_unit])
	var pawn_presence: float = BoardScoring.PRESENCE_CRITERION_WEIGHT \
			* BoardScoring.presence_value(BoardState.UnitState.from_instance(pawn_unit))
	check_eq(captain_only_scoring.score(pawn_only), pawn_presence,
			"with a 0 default weight only the presence term remains for untagged units")


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
	check_eq(BoardScoring.weight_for(king, weights), 1.75, "is_king resolves as the captain entry")
	var untagged := BoardState.UnitState.from_instance(_enemy("pawn", 0, 1))
	check_eq(BoardScoring.weight_for(untagged, weights), 0.1, "no role falls to the default entry")
	check_eq(BoardScoring.weight_for(untagged, {"pawn": 7.0}), 7.0, "a card-id entry wins over everything")
	# The per-event override layer: stock() merges encounter entries over the stock table.
	var overridden := BoardScoring.stock({"fodder": 0.8})
	var dr: BoardScoring.DeathRisk = overridden.criteria[0]
	check_eq(BoardScoring.weight_for(fodder, dr.survival_weights), 0.8,
			"an encounter override rewrites one role's worth, stock fills the rest")
	check_eq(BoardScoring.weight_for(king, dr.survival_weights), 1.75,
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
	check_eq(BoardScoring.harm(state, cap), 0.5, "…but harm is 10/20 of the unit, capped by max")

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


# ── Damage sharing (stock): moderate threat, and the king fronts for its troops ──────

func _engine_king_shares_moderate_threat() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# The other half of the stock captain's character (weight 1.75 is PROVISIONAL and
	# untested in play — see STOCK_SURVIVAL_WEIGHTS): against MODERATE threat the king leaves its safe corner
	# and walks to the front line, spending its fat pool so valued fodders stop dying.
	# Against queens the same board makes it stay home (the retreat test covers commitment).
	var captain := _enemy("captain_dummy", back, deep)
	var enemies: Array = [captain]
	for r in BoardData.ROWS:
		enemies.append(_enemy("fodder_dummy", r, 1))
	var players: Array = [_player("knight", 0, deep), _player("knight", 1, deep)]
	var grids := _grids(enemies, players)

	var engine := _seeded_engine()
	engine.weight_overrides = {"fodder": 0.5}
	var actions := engine.decide_actions([], grids[0], grids[1], 0)

	var king_moves: Array = actions.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.MOVE and a["inst"] == captain)
	check_eq(king_moves.size(), 1, "the stock king steps out against moderate threat")
	if not king_moves.is_empty():
		check_eq(int(king_moves[0]["col"]), 0,
				"…all the way to the front line, absorbing hits for its fodders")


# ── The sim-support gate: the engine never plays what it cannot evaluate ─────────────

func _sim_gate() -> void:
	check(SimEffects.can_simulate_cast(AbilityData.get_ability("heal").effects),
			"a manual heal is simulatable")
	check(SimEffects.can_simulate_cast(AbilityData.get_ability("magic_missile").effects),
			"a manual damage bolt is simulatable")
	check(SimEffects.can_simulate_cast(CardData.get_card("dummy_group_heal").effects),
			"an all-allies heal is simulatable")
	check(not SimEffects.can_simulate_cast(AbilityData.get_ability("fire_bless").effects),
			"a status-applying cast is REFUSED — the sim has no status story yet")
	check(not SimEffects.can_simulate_cast([Effect.from_dict({
		"trigger": "on_play", "targeting_policy": "manual",
		"attribute": "health", "amount": -2, "chance": 0.5,
	})]), "a probabilistic cast is refused — the sim would have to guess the roll")
	check(not SimEffects.can_simulate_cast([Effect.from_dict({
		"trigger": "on_play", "targeting_policy": "manual",
		"attribute": "health", "amount": 2,
		"conditions": [{"attribute": "health", "comparator": "lte", "value": 3}],
	})]), "a condition-gated cast is refused — target eligibility isn't evaluated sim-side")
	check(SimEffects.needs_manual(AbilityData.get_ability("heal").effects),
			"the heal wants a picked target")
	check(not SimEffects.needs_manual(CardData.get_card("dummy_group_heal").effects),
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
	check_eq(cands.size(), fielded,
			"the support offers heal at every fielded unit; status-applying fire_bless is refused")
	for cand: Dictionary in cands:
		check_eq((cand["ability"] as AbilityData).id, "heal", "…and only heal")
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
	var state := _state_with([_enemy("captain_dummy", back, deep), support, wounded])

	var next := CandidateApply.apply(state, {"kind": "ability", "inst": support,
			"ability": AbilityData.get_ability("heal"), "target": wounded, "cost": 1})
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
	var state := _state_with([_enemy("captain_dummy", back, deep), hurt_a, hurt_b, full], [foe])

	var group_heal := unit("dummy_group_heal")
	group_heal.owner = 1
	var next := CandidateApply.apply(state,
			{"kind": "cast", "inst": group_heal, "target": null, "cost": 4})
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
	var state := _state_with([_enemy("captain_dummy", back, deep), burst], [victim])

	var next := CandidateApply.apply(state, {"kind": "ability", "inst": burst,
			"ability": AbilityData.get_ability("magic_missile"), "target": victim, "cost": 3})
	check(next.find(victim) == null, "a simulated kill removes the unit from the board copy")
	check(state.find(victim) != null, "…only the copy")
	check_eq(victim.current_health, 2, "…and never the live instance")


# ── Presence: the fielding pole of the place-vs-preserve arbitration ─────────────────

func _presence_measurement() -> void:
	var fodder := BoardState.UnitState.from_instance(_enemy("fodder_dummy", 0, 0))
	var dps := BoardState.UnitState.from_instance(_enemy("dps_dummy", 0, 1))
	check_eq(BoardScoring.presence_value(fodder), 1.0, "presence v1 is the unit's mana cost")
	check(BoardScoring.presence_value(dps) > BoardScoring.presence_value(fodder),
			"a costlier unit is worth more on the board")
	# The linearity property the greedy loop leans on: a budget converts to the same total
	# presence however it is split, so greedy ordering never changes a spent turn's worth.
	check_eq(BoardScoring.presence_value(dps),
			BoardScoring.presence_value(fodder) * 2.0, "cost 2 is exactly two cost 1s")


# ── The engine end to end: the support tends its wounded ─────────────────────────────

func _engine_heals_wounded_ally() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# A precious wounded dps under real threat, a healthy board otherwise, and one mana:
	# the only improving play is the support's heal, aimed at the dying unit.
	var support := _enemy("support_dummy", back, 1)
	var wounded := _enemy("dps_dummy", 0, 2)
	wounded.current_health = 1
	var enemies: Array = [_enemy("captain_dummy", back, deep), support, wounded,
			_enemy("fodder_dummy", back, 0), _enemy("fodder_dummy", 0, 0)]
	var players: Array = [_player("knight", 0, deep), _player("knight", 1, deep)]
	var grids := _grids(enemies, players)

	var engine := _seeded_engine()
	engine.weight_overrides = {"dps": 0.6}
	var actions := engine.decide_actions([], grids[0], grids[1], 1)

	var heals: Array = actions.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.GENERATE)
	check_eq(heals.size(), 1, "the support heals exactly once (the tap is spent)")
	if not heals.is_empty():
		check_eq((heals[0]["ability"] as AbilityData).id, "heal", "…casting heal")
		check(heals[0]["unit"] == support, "…from the support")
		check(heals[0]["target"] == wounded, "…at the dying dps, not anyone comfortable")

	# The futility gate: a fully healthy board offers the same legal heal, but no target
	# improves anything — the engine declines rather than waste the play.
	var healthy_enemies: Array = [_enemy("captain_dummy", back, deep),
			_enemy("support_dummy", back, 1), _enemy("dps_dummy", 0, 2)]
	var healthy_grids := _grids(healthy_enemies, players)
	var idle := _seeded_engine()
	idle.weight_overrides = {"dps": 0.6}
	var idle_actions: Array = idle.decide_actions([], healthy_grids[0], healthy_grids[1], 1) \
			.filter(func(a: Dictionary) -> bool:
				return int(a["type"]) == EnemyEngine.Action.GENERATE)
	check_eq(idle_actions.size(), 0, "nothing wounded → the heal is declined, not wasted")


func _engine_casts_group_heal() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# Three wounded precious fodders and the group heal in hand: the area cast is the
	# improving play. (No support on board — the single heal isn't available to shadow it.)
	var hurt: Array = []
	for r in 3:
		var f := _enemy("fodder_dummy", r, 1)
		f.current_health = 1
		hurt.append(f)
	var enemies: Array = [_enemy("captain_dummy", back, deep)] + hurt
	var players: Array = [_player("knight", 0, deep), _player("knight", 1, deep)]
	var grids := _grids(enemies, players)
	var group_heal := unit("dummy_group_heal")
	group_heal.owner = 1

	var engine := _seeded_engine()
	engine.weight_overrides = {"fodder": 0.5}
	var actions := engine.decide_actions([group_heal], grids[0], grids[1], 4)

	var casts: Array = actions.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.CAST)
	check_eq(casts.size(), 1, "the group heal is cast")
	if not casts.is_empty():
		check(casts[0]["inst"] == group_heal, "…the spell from hand")
		check(casts[0]["target"] == null, "…with no manual target (area)")


# ── Place vs heal: one score, both directions ────────────────────────────────────────

# ONE mana, both plays legal — place a fresh fodder (presence + cover) or heal a precious
# unit. The precious unit is a BUILDING on the front line so the choice is pure: it cannot
# retreat, and no placement can stand in front of the front column — healing is the only
# way to preserve it, fielding the only way to grow. (Free MOVE actions may interleave;
# the assertion is about where the one mana goes.)
func _engine_place_vs_heal_arbitration() -> void:
	var back := BoardData.ROWS - 1
	var deep := BoardData.COLS - 1
	# MODERATE threat is the point: under overwhelming threat the urgency measure calls
	# the tower doomed with or without the heal (triage — correctly declined), and with
	# none there is nothing to preserve. One knight's worth of pressure is the window
	# where +2 health genuinely changes whether the tower lives.
	var players: Array = [_player("knight", 0, deep)]

	# Direction 1 — the tower is dying: preservation wins the mana.
	var dying_tower := _enemy("rook", 1, 0)
	dying_tower.current_health = 1
	dying_tower.current_shield = 0
	var support := _enemy("support_dummy", back, 1)
	var enemies: Array = [_enemy("captain_dummy", back, deep), support, dying_tower]
	var grids := _grids(enemies, players)
	var engine := _seeded_engine()
	engine.weight_overrides = {"rook": 1.2}
	var actions := engine.decide_actions([unit("fodder_dummy")], grids[0], grids[1], 1)
	var heals: Array = actions.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.GENERATE)
	var places: Array = actions.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.PLACE)
	check_eq(heals.size(), 1, "the dying tower pulls the mana into the heal")
	if not heals.is_empty():
		check(heals[0]["target"] == dying_tower, "…aimed at the tower")
	check_eq(places.size(), 0, "…so the fodder stays in hand")

	# Direction 2 — the same board, tower untouched: the heal is futile and the same
	# mana fields the fodder instead.
	var whole_tower := _enemy("rook", 1, 0)
	whole_tower.current_shield = 0
	var enemies2: Array = [_enemy("captain_dummy", back, deep),
			_enemy("support_dummy", back, 1), whole_tower]
	var grids2 := _grids(enemies2, players)
	var engine2 := _seeded_engine()
	engine2.weight_overrides = {"rook": 1.2}
	var actions2 := engine2.decide_actions([unit("fodder_dummy")], grids2[0], grids2[1], 1)
	var heals2: Array = actions2.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.GENERATE)
	var places2: Array = actions2.filter(func(a: Dictionary) -> bool:
		return int(a["type"]) == EnemyEngine.Action.PLACE)
	check_eq(places2.size(), 1, "with nothing to preserve, the same mana fields the fodder")
	check_eq(heals2.size(), 0, "…and the futile heal is declined")


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
	# the dps, one where it was never there. Identical geometry, identical survivors; the
	# only difference is that one of them cost a unit to get to. That must score worse,
	# and nothing but the graveyard term can say so.
	var doomed := _enemy("dps_dummy", 0, 0)
	doomed.current_health = 1
	var before := _state_with([_enemy("captain_dummy", back, deep), doomed], players)
	var burst := BoardState.UnitState.from_instance(_enemy("burst_damage_dummy", 0, 1))
	var killed := before.copy()
	SimEffects.apply_cast(killed, AbilityData.get_ability("magic_missile").effects, 1,
			burst, killed.find(doomed))
	var never_there := _state_with([_enemy("captain_dummy", back, deep)], players)

	check(killed.find(doomed) == null, "the bolt did kill the dps (fixture sanity)")
	check_eq(killed.graveyard.size(), 1, "…and the corpse is recorded")
	check(scoring.score(killed) < scoring.score(never_there),
			"reaching a board by KILLING an own unit scores worse than the same board without it")
	check(scoring.score(killed) < scoring.score(before),
			"…and worse than leaving the dying unit alive")
	check_eq(BoardState.capture(_grids([])[0], _grids([])[1]).graveyard.size(), 0,
			"a freshly captured board starts with an empty graveyard")

	# A dead PLAYER unit is not a loss to mourn — it stops contributing threat, which the
	# threat mass already rewards. It must never be charged to the enemy's own risk.
	var victim := _player("knight", 0, deep)
	victim.current_health = 1
	var with_foe := _state_with([_enemy("captain_dummy", back, deep)], [victim])
	var foe_killed := with_foe.copy()
	SimEffects.apply_cast(foe_killed, AbilityData.get_ability("magic_missile").effects, 1,
			burst, foe_killed.find(victim))
	check(scoring.score(foe_killed) > scoring.score(with_foe),
			"killing a PLAYER unit is still an improvement — the graveyard is own-side only")


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
			"ability": AbilityData.get_ability("magic_missile"), "target": captain, "cost": 3})
	check(scoring.score(suicide) < scoring.score(state),
			"killing its own Captain scores worse than doing nothing at all")
