extends Node
# The full-stack repro: boots the REAL main scene (shell + chrome), navigates to the fight
# exactly as the game does, clicks the player king's card with a real input event, and
# reports the selection chain plus a screenshot.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_selection_shell_probe.tscn
const OUT := "res://dev/_selection_shell_out.png"


func _ready() -> void:
	print("PROBE start")
	get_tree().create_timer(20.0).timeout.connect(func() -> void:
		print("PROBE WATCHDOG quit")
		get_tree().quit())
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await get_tree().create_timer(1.0).timeout
	Nav.goto("res://scenes/fight_screen.tscn")
	await get_tree().create_timer(2.0).timeout
	var screen: FightScreen = _find_fight(get_tree().root)
	if screen == null or screen.world == null:
		print("PROBE no fight screen mounted")
		get_tree().quit()
		return
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
	print("PROBE clicking at ", at, " content_scale=",
			get_viewport().content_scale_factor)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	Input.parse_input_event(press)
	await get_tree().create_timer(0.1).timeout
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	Input.parse_input_event(release)
	await get_tree().create_timer(1.2).timeout
	print("PROBE holds unit: ", Selection.holds(unit),
			" selected_now=", card._selected_now, " scale=", card.scale)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT)
	print("PROBE rendered")
	get_tree().quit()


func _find_fight(node: Node) -> FightScreen:
	if node is FightScreen:
		return node as FightScreen
	for child: Node in node.get_children():
		var found: FightScreen = _find_fight(child)
		if found != null:
			return found
	return null
