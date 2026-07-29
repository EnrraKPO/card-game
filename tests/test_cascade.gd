extends TestCase

# CombatCascade: the re-homed event cascade (Step 3 of COMBAT_DECOUPLING_REFACTOR.md).
# Runs the REAL cascade headless — a CombatWorld with no view, the null presenter — which is
# exactly the shape Step 5's simulations use. Pins: synchronous completion under the null
# presenter, phase-moment status decay, bury's state half + the world's unit_retired wire,
# and the run-modifiers context re-point (a world's context carries the WORLD's set, not the
# ambient global).


func suite_name() -> String:
	return "Combat cascade"


func run() -> void:
	_resolve_event_decays()
	_bury_retires_and_signals()
	_context_repoint()


func _headless_world() -> CombatWorld:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	return w


func _place(w: CombatWorld, card_id: String, side_owner: int, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	inst.owner = side_owner
	inst.row = r
	inst.col = c
	var grid: Array = w.grid_of(side_owner)
	var grid_row: Array = grid[r]
	grid_row[c] = inst
	return inst


func _resolve_event_decays() -> void:
	var w := _headless_world()
	var pawn := _place(w, "pawn", 0, 0, 0)
	var atk0 := pawn.get_attribute("attack")
	pawn.apply_status("empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check_eq(pawn.get_attribute("attack"), atk0 + 2, "empowered folds before the cascade runs")

	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_end")
		await cascade.resolve_event(&"turn_end")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the cascade runs SYNCHRONOUSLY under the null presenter")
	check(pawn.find_status("empowered") == null, "two turn-ends expire empowered through the real decay tier")
	check_eq(pawn.get_attribute("attack"), atk0, "the expired status stops folding")


func _bury_retires_and_signals() -> void:
	var w := _headless_world()
	var pawn := _place(w, "pawn", 0, 1, 2)
	var retired: Array = []
	w.unit_retired.connect(func(inst: CardInstance) -> void: retired.append(inst))

	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.bury(pawn)
		done[0] = true
	chain.call()
	check(bool(done[0]), "bury completes synchronously without any view")
	var row: Array = w.player_grid[1]
	check(row[2] == null, "bury's state half clears the cell")
	check(retired.size() == 1 and retired[0] == pawn, "the world's unit_retired wire fires — where bounties hang")


func _context_repoint() -> void:
	# The world amendment's teeth: run-scope dispatch reads the CONTEXT's modifier set, and a
	# world's context carries the WORLD's own reference — not the ambient global.
	var own_set := ModifierSet.new()
	var w := _headless_world()
	w.modifiers = own_set
	var ctx := w.make_context(unit("pawn"))
	check(ctx.run_modifiers == own_set, "a world's context carries the world's own modifier set")
	check(ctx.player_side == w.player_side, "…and the world's sides")

	# Contexts built OUTSIDE a world (tests, legacy paths) default to the live run set at
	# construction — the ambient read is confined to that boundary.
	var bare := EffectContext.make(unit("pawn"), [[]], [[]])
	check(bare.run_modifiers == GameData.current_modifiers,
			"a bare context defaults to the live run set at build time")
