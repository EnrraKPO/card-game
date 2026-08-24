extends Node
# End-to-end DRAG gesture through real input: wait for the command window, press the hand
# unit card and drag it in steps onto an empty own slot, release to drop — the unit fields
# through the same session the click path uses. Screenshots mid-drag and after the drop.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_drag_flow_probe.tscn
const OUT_SELECTED := "res://dev/_drag_mid_out.png"
const OUT_PLACED := "res://dev/_drag_dropped_out.png"


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
	var subject: Variant = ui.subject()
	var destination := Vector3i(0, 2, 2)   # an empty own slot away from the king
	var from: Vector2 = ui.get_global_rect().get_center()
	var to: Vector2 = screen._slot_uis[destination].get_global_rect().get_center()
	_press(from)
	# Godot begins the drag after ~10px of held RELATIVE drift — walk there in steps.
	var last: Vector2 = from
	for step: int in range(1, 13):
		var next: Vector2 = from.lerp(to, step / 12.0)
		_move(next, next - last)
		last = next
		await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	print("PROBE mid-drag: action active=", screen._interaction.active(),
			" is_drag=", screen._interaction.active()
					and screen._interaction.current().is_drag)
	var cued := 0
	for address: Vector3i in screen._slot_uis:
		if screen._slot_uis[address]._cue == SlotUI.Cue.MOVE:
			cued += 1
	print("PROBE mid-drag destination cues: ", cued)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT_SELECTED)
	var target: SlotUI = screen._slot_uis[destination]
	print("PROBE gui_is_dragging=", get_viewport().gui_is_dragging(),
			" gate=", target._can_drop_data(Vector2.ZERO, ui),
			" owns=", screen._interaction.owns_drag(ui),
			" role=", screen._interaction.role_of(target))
	# Synthetic releases don't traverse Godot's internal drop dispatch reliably; the REAL
	# drop calls exactly this pair on the target — invoke it, then release to end the drag.
	if target._can_drop_data(Vector2.ZERO, ui):
		target._drop_data(Vector2.ZERO, ui)
	_release(to)
	await get_tree().create_timer(1.5).timeout
	var fielded: Unit = SlotViewModel.occupant(
			screen.world.board_manager.slot_at(destination))
	var somewhere := Vector3i(-9, -9, -9)
	for address: Vector3i in screen._slot_uis:
		if SlotViewModel.occupant(screen.world.board_manager.slot_at(address)) == subject:
			somewhere = address
	print("PROBE fielded at drop slot: ", fielded == subject,
			" anywhere=", somewhere,
			" picking=", screen._picking,
			" hand_count=", screen._hand.card_count(),
			" action ended: ", not screen._interaction.active())
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT_PLACED)
	print("PROBE rendered")
	get_tree().quit()


func _press(at: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	Input.parse_input_event(press)


func _move(at: Vector2, rel: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.relative = rel
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(motion)


func _release(at: Vector2) -> void:
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	Input.parse_input_event(release)
