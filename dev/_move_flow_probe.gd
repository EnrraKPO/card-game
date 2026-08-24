extends Node
# Move flow: select the fielded King (the move session begins - MOVE cues + MoveButtons),
# screenshot, then commit through the button path; the King repositions on the core road.
const OUT := "res://dev/_move_flow_out.png"
func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		print("PROBE WATCHDOG")
		get_tree().quit())
	var screen := FightScreen.new()
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	while not (screen._span_active and screen._awaiting_command):
		await get_tree().create_timer(0.2).timeout
	var origin := Vector3i(0, 1, 0)
	var king: Unit = SlotViewModel.occupant(screen.world.board_manager.slot_at(origin))
	screen._on_slot_clicked(origin)
	print("PROBE immediately after click: session=", screen._interaction.active())
	await get_tree().create_timer(0.4).timeout
	print("PROBE holds=", Selection.holds(king),
			" span=", screen._span_active, " awaiting=", screen._awaiting_command,
			" own=", king.allegiance == screen.world.player_side(),
			" building=", king.is_building,
			" standing=", TargetResolver.standing_address(king),
			" has_card=", screen._card_uis.has(king))
	var buttons := 0
	for address: Vector3i in screen._slot_uis:
		if screen._slot_uis[address]._move_btn != null 				and screen._slot_uis[address]._move_btn.visible:
			buttons += 1
	print("PROBE session=", screen._interaction.active(),
			" click_commit=", screen._interaction.active()
					and screen._interaction.current().click_commit,
			" move_buttons=", buttons)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT)
	var destination := Vector3i(0, 0, 1)
	screen._on_move_button_pressed(screen._slot_uis[destination])
	await get_tree().create_timer(1.5).timeout
	print("PROBE king moved: ", SlotViewModel.occupant(
			screen.world.board_manager.slot_at(destination)) == king,
			" origin empty: ", SlotViewModel.occupant(
			screen.world.board_manager.slot_at(origin)) == null,
			" session ended: ", not screen._interaction.active())
	print("PROBE rendered")
	get_tree().quit()
