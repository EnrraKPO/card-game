extends Node
# End-to-end place gesture through real input: wait for the player's command window with
# mana for a unit, click the hand card (select — glow/lift/cues), then click an empty own
# slot (commit — the unit fields with no picker prompt). Screenshots both moments.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_place_flow_probe.tscn
const OUT_SELECTED := "res://dev/_place_selected_out.png"
const OUT_PLACED := "res://dev/_place_placed_out.png"


func _ready() -> void:
	print("PROBE start")
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("PROBE WATCHDOG quit")
		get_tree().quit())
	var screen := FightScreen.new()
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Wait for a command window where some hand UNIT is affordable.
	var unit_index := -1
	while unit_index < 0:
		await get_tree().create_timer(0.25).timeout
		if not (screen._span_active and screen._awaiting_command):
			continue
		var members: Array[GameEntity] = screen.world.player_side() \
				.get_container(&"hand").members
		for index: int in members.size():
			var card := members[index] as Card
			if card is Unit and card.payable():
				unit_index = index
				break
		if unit_index < 0 and screen._awaiting_command:
			screen.commanded.emit(null)   # pass the turn until one is affordable
	print("PROBE affordable unit at hand index ", unit_index)
	var ui: CardUI = screen._hand.card_at(unit_index)
	_click(ui.get_global_rect().get_center())
	await get_tree().create_timer(0.4).timeout
	var selected: CardUI = screen._hand.selected()
	print("PROBE hand selected: ", selected == ui,
			" action active: ", screen._interaction.active())
	var destination := Vector3i(-1, -1, -1)
	var cued := 0
	for address: Vector3i in screen._slot_uis:
		if screen._slot_uis[address]._cue == SlotUI.Cue.MOVE:
			cued += 1
			if destination.x < 0:
				destination = address
	print("PROBE destination cues: ", cued)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT_SELECTED)
	if destination.x < 0:
		print("PROBE no destination cue — stopping")
		get_tree().quit()
		return
	var subject: Variant = ui.subject()
	_click(screen._slot_uis[destination].get_global_rect().get_center())
	await get_tree().create_timer(1.5).timeout
	var fielded: Unit = SlotViewModel.occupant(
			screen.world.board_manager.slot_at(destination))
	print("PROBE fielded at destination: ", fielded == subject,
			" action ended: ", not screen._interaction.active())
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT_PLACED)
	print("PROBE rendered")
	get_tree().quit()


func _click(at: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	Input.parse_input_event(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	Input.parse_input_event(release)
