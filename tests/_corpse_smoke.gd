extends Node

# CORPSE DISPOSAL smoke: builds a REAL CombatBoard (SlotUI grids + CardUI), kills a unit
# outright, and asserts the board is rid of both halves of it — the STATE (the unit is
# undocked; nothing stands at its address) and the VIEW (no card is left in the slot).
#
# It exists because those two came apart. Retiring a unit undocks it, and the view's
# "which card is this unit's" lookup used to route through placement — so the moment the
# state was correct the view could no longer find the card it had to dispose of, and a
# corpse stood on the board at negative health. Where a unit STANDS and where its card is
# BEING DRAWN are two facts with two lifetimes, and a death is the window where they differ.
#   Godot_console.exe --headless --path . res://tests/_corpse_smoke.tscn

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
	var world := CombatWorld.new()
	world.player_side = board.player_side
	world.enemy_side = board.enemy_side
	world.modifiers = GameData.current_modifiers
	board.world = world

	var at := BoardLocation.at(1, 1, 2)
	var victim := CardInstance.from_data(CardData.get_card("pawn"))
	board.place_enemy_card(victim, at)
	var slot := board.slot_ui_for(at)

	if slot.get_card() == null:
		failures += 1
		print("FAIL: fixture — the victim's card never stood in its slot")

	# The card must still be findable while the unit is alive.
	if board.get_card_ui(victim) == null:
		failures += 1
		print("FAIL: a living unit's card is not findable")

	# Overkill, exactly as reported: well past zero, not merely at it.
	Arbitrator.submit(StatMutation.damage(victim, victim.current_health + 6, null))
	if victim.current_health >= 0:
		print("NOTE: victim at %d health" % victim.current_health)

	# The card must STILL be findable the instant the unit leaves play — that is the whole
	# window in which the death is presented and the corpse disposed of.
	world.retire(victim)
	var corpse := board.get_card_ui(victim)
	if corpse == null:
		failures += 1
		print("FAIL: a retired unit's card is unreachable — nothing can dress or dispose of it")

	board.drop_card_view(victim, corpse)

	if world.location_of(victim) != null:
		failures += 1
		print("FAIL: the dead unit is still docked")
	if slot.get_card() != null:
		failures += 1
		print("FAIL: the corpse's card is STILL standing in its slot")
	if board.get_card_ui(victim) != null:
		failures += 1
		print("FAIL: the corpse's card is still findable after disposal")

	# ── And the same through the SWEEP path, which is how an effect-kill leaves ──
	var at2 := BoardLocation.at(1, 0, 0)
	var swept := CardInstance.from_data(CardData.get_card("pawn"))
	board.place_enemy_card(swept, at2)
	var slot2 := board.slot_ui_for(at2)
	Arbitrator.submit(StatMutation.damage(swept, swept.current_health + 6, null))
	board.cleanup_effect_deaths()   # world sweep -> unit_swept -> the board drops the card

	if world.location_of(swept) != null:
		failures += 1
		print("FAIL: the swept unit is still docked")
	if slot2.get_card() != null:
		failures += 1
		print("FAIL: the swept corpse's card is STILL standing in its slot")

	print("CORPSE SMOKE: %s" % ("OK" if failures == 0 else "%d FAILURES" % failures))
	get_tree().quit(0 if failures == 0 else 1)
