extends Node
# Strike presentation probe: places a unit, ends the turn, and screenshots the combat span
# mid-strike; prints the cue log tail as the record of dispatched cues.
const OUT_A := "res://dev/_strike_a_out.png"
const OUT_B := "res://dev/_strike_b_out.png"
const OUT_C := "res://dev/_strike_c_out.png"
func _ready() -> void:
	get_tree().create_timer(45.0).timeout.connect(func() -> void:
		print("PROBE WATCHDOG")
		get_tree().quit())
	var screen := FightScreen.new()
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Round 1: pass. Round 2: place the first affordable unit front row, then end turn.
	for round_index: int in 2:
		while not (screen._span_active and screen._awaiting_command):
			await get_tree().create_timer(0.15).timeout
		if round_index == 1:
			var members: Array[GameEntity] = screen.world.player_side() 					.get_container(&"hand").members
			for index: int in members.size():
				var card := members[index] as Card
				if card is Unit and card.payable():
					screen._pending_destination = Vector3i(0, 1, 1)
					screen.commanded.emit(Event.new(&"play", card))
					break
			while not (screen._span_active and screen._awaiting_command):
				await get_tree().create_timer(0.15).timeout
		screen.commanded.emit(null)   # end turn -> combat span runs
		await get_tree().create_timer(0.4).timeout
	await get_tree().create_timer(0.2).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT_A)
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT_B)
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT_C)
	await get_tree().create_timer(2.0).timeout
	print("PROBE cue log: ", "
".join(screen._cue_lines))
	print("PROBE rendered")
	get_tree().quit()
