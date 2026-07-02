extends Control

# The final stage's boss is down — the run is won. Ends the run (clearing it while
# keeping the save's meta-progression) and returns to the save's hub.

func _ready() -> void:
	Nav.clear_back()   # terminal screen — the OS back gesture stays inert (use the on-screen button)
	var compact := UIScale.is_compact()

	# No screen-wide background here — Shell already paints the app's one BG_COLOR behind every
	# screen; the gold "victory" mood lives in the title's color below instead.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 32)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Run Successful!"
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color("9c7a10"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "You vanquished the final boss and conquered the run."
	subtitle.add_theme_font_size_override("font_size", 30 if compact else 26)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var continue_btn := ScreenUI.action_button("Return to your realm", _on_continue,
		Vector2(380, 96) if compact else Vector2(360, 78), 32 if compact else 26,
		ScreenUI.CHROME_CONFIRM)
	continue_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	vbox.add_child(continue_btn)


func _on_continue() -> void:
	GameData.end_run()
	Nav.goto("res://scenes/game_world.tscn")
