extends Control

# Shown when the King falls — the run is lost. The run has already been ended by combat
# (meta-progression kept); this is the "you lost" beat before returning to the hub.

func _ready() -> void:
	Nav.clear_back()   # terminal screen — the OS back gesture stays inert (use the on-screen button)
	var compact := UIScale.is_compact()

	# No screen-wide background here — Shell already paints the app's one BG_COLOR behind every
	# screen; the red "defeat" mood lives in the title's color below instead.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 32)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Run Over"
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color("8a2020"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Your King has fallen. The run ends here."
	subtitle.add_theme_font_size_override("font_size", 30 if compact else 26)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var continue_btn := ScreenUI.action_button("Return to your realm", _on_continue,
		Vector2(380, 96) if compact else Vector2(360, 78), 32 if compact else 26,
		ScreenUI.CHROME_NEUTRAL)
	continue_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	vbox.add_child(continue_btn)


func _on_continue() -> void:
	Nav.goto("res://scenes/game_world.tscn")
