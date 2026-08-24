extends Node
# Drives selection through REAL input events on the ROOT viewport — a mouse press+release
# on the player king's card inside the fight screen — and reports the chain.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_selection_click_probe.tscn
const OUT := "res://dev/_selection_click_out.png"


func _ready() -> void:
	print("PROBE start")
	get_tree().create_timer(12.0).timeout.connect(func() -> void:
		print("PROBE WATCHDOG quit")
		get_tree().quit())
	var screen := FightScreen.new()
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await get_tree().create_timer(1.5).timeout
	var unit: Unit = null
	for row: int in BoardGeometry.ROWS:
		for col: int in BoardGeometry.COLS:
			var found: Unit = SlotViewModel.occupant(
					screen.world.board_manager.slot_at(Vector3i(0, row, col)))
			if found != null and unit == null:
				unit = found
	var card: CardUI = screen._card_uis.get(unit)
	if card == null:
		print("PROBE no card ui")
		get_tree().quit()
		return
	var at: Vector2 = card.get_global_rect().get_center()
	print("PROBE clicking at ", at)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	print("PROBE pushing press")
	Input.parse_input_event(press)
	await get_tree().create_timer(0.1).timeout
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	print("PROBE pushing release")
	Input.parse_input_event(release)
	await get_tree().create_timer(0.15).timeout
	print("PROBE holds unit: ", Selection.holds(unit),
			" selected_now=", card._selected_now, " scale=", card.scale)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT)
	print("PROBE rendered")
	get_tree().quit()
