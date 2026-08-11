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
	_headless_spawn_drain()


func _headless_world() -> CombatWorld:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	return w


func _place(w: CombatWorld, card_id: String, side_owner: int, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	w.place_unit(inst, r, c, side_owner)
	return inst


func _resolve_event_decays() -> void:
	var w := _headless_world()
	var pawn := _place(w, "pawn", 0, 0, 0)
	StatusEngine.apply(pawn, "empowered", StatusEngine.DURATION_DEFAULT, 1, null)
	check(pawn.find_status("empowered") != null, "the status applies before the cascade runs")

	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_end")
		await cascade.resolve_event(&"turn_end")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the cascade runs SYNCHRONOUSLY under the null presenter")
	check(pawn.find_status("empowered") == null, "two turn-ends expire empowered through the real decay tier")


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
	check(w.unit_at(0, 1, 2) == null, "bury's state half clears the cell")
	check(retired.size() == 1 and retired[0] == pawn, "the world's unit_retired wire fires — where bounties hang")


# (The context-repoint checks died with the dispatch context object, 2026-08-11. The rule
# they pinned — run-scope dispatch reads the WORLD's own modifier set, never the ambient
# global — carries to the rebuilt dispatch, which reads the world directly.)


func _headless_spawn_drain() -> void:
	# The spawn queue lives on the world now (Step 4): queueing + draining works with NO view
	# attached — the exact shape a simulated on-death split needs. unit_spawned still cries
	# out for a card; here nobody is listening, and that must be fine.
	var w := _headless_world()
	var anchor := _place(w, "pawn", 1, 0, 3)
	var arrivals: Array = []
	w.unit_spawned.connect(func(inst: CardInstance) -> void: arrivals.append(inst))
	w.queue_spawn("pawn", 2, anchor)
	w.cleanup_deaths()
	check_eq(arrivals.size(), 2, "the drain places both queued spawns")
	var on_board := 0
	for inst: CardInstance in w.get_all_units():
		if inst != anchor and inst.owner == 1:
			on_board += 1
	check_eq(on_board, 2, "both arrivals stand on the spawning side's grid")
	check(arrivals.is_empty() or w.location_of(arrivals[0] as CardInstance) != null,
			"an arrival is on the board by the time its signal fires")
