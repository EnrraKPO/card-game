extends Node

# Spawn-payload smoke (enemy-sets engine verification): builds a REAL CombatBoard (SlotUI
# grids + CardUI), kills a splitting slime and a phase-change boss through the Resolver, and
# asserts the queued spawns land after the death sweep. Runs with an in-memory profile —
# never touches a save slot (the stock _combat_smoke uses select_slot; this one must not).
#   Godot_console.exe --headless --path . res://tests/_spawn_smoke.tscn

func _ready() -> void:
	GameData.current_profile = ProfileData.from_dict({})
	GameData.current_modifiers = ModifierSet.new()
	var failures := 0

	var board := CombatBoard.new()
	add_child(board)
	board.setup_grids()
	var row := HBoxContainer.new()
	add_child(row)
	board.build_section(row, true)
	board.build_section(row, false)
	board.player_side = CombatSide.new()
	board.enemy_side = CombatSide.new()
	# The board is a view over a CombatWorld — the world OWNS placement (see LocationManager)
	# and the board reads it. Same wiring combat does.
	var world := CombatWorld.new()
	world.player_side = board.player_side
	world.enemy_side = board.enemy_side
	world.modifiers = GameData.current_modifiers
	board.world = world

	# ── Split on death: Green Slime dies → 2 Droplets, first reclaiming its slot ──
	var slime := CardInstance.from_data(CardData.get_card("slime_green"))
	board.place_enemy_card(slime, 1, 1)
	Resolver.submit(StatMutation.damage(slime, 99, null))
	# The Resolver only mutates — COMBAT broadcasts `death` and then sweeps (events ≠
	# mutations). Mirror that here: fire the corpse's death effects, then clean up.
	EffectSystem.trigger(GameEvent.make(&"death", slime), slime, board.make_context(slime))
	board.cleanup_effect_deaths()
	var droplets := 0
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var u: CardInstance = board.enemy_grid[r][c]
			if u != null and u.data.id == "slime_droplet":
				droplets += 1
	if droplets != 2:
		failures += 1
		print("FAIL: green slime split — want 2 droplets, got %d" % droplets)
	var reclaimer: CardInstance = board.enemy_grid[1][1]
	if reclaimer == null or reclaimer.data.id != "slime_droplet":
		failures += 1
		print("FAIL: first droplet should reclaim the corpse slot")

	# ── Phase-change boss: Slimeon dies → Slimeon Reborn (is_king) → fight continues ──
	var boss := CardInstance.from_data(CardData.get_card("slime_overlord"))
	board.place_enemy_card(boss, 2, 3)
	Resolver.submit(StatMutation.damage(boss, 999, null))
	EffectSystem.trigger(GameEvent.make(&"death", boss), boss, board.make_context(boss))
	board.cleanup_effect_deaths()
	var reborn: CardInstance = board.enemy_grid[2][3]
	if reborn == null or reborn.data.id != "slime_overlord_reborn":
		failures += 1
		print("FAIL: boss death should spawn Slimeon Reborn in its slot, got %s"
				% (reborn.data.id if reborn != null else "empty"))
	elif not reborn.data.is_king:
		failures += 1
		print("FAIL: the reborn form must be a king")
	# Give the player a king so the win check reads both sides.
	var pk := CardInstance.from_data(CardData.get_card("king"))
	world.place_unit(pk, 2, 0, 0)
	if board.any_king_dead():
		failures += 1
		print("FAIL: fight should CONTINUE — the reborn king keeps the enemy side alive")

	# ── strikes read on a live board unit ──
	var talon := CardInstance.from_data(CardData.get_card("harpy_talon"))
	board.place_enemy_card(talon, 0, 0)
	if talon.get_attribute("strikes") != 2:
		failures += 1
		print("FAIL: Twin-Talon Harpy should read 2 strikes")

	print("SPAWN SMOKE: %s" % ("OK" if failures == 0 else "%d FAILURES" % failures))
	get_tree().quit(0 if failures == 0 else 1)
