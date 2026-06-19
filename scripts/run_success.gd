extends Control

# The final stage's boss is down — the run is won. Ends the run (clearing it while
# keeping the save's meta-progression) and returns to the save's hub.

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var compact := UIScale.is_compact()

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.09, 0.08, 0.04)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 32)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Run Successful!"
	title.add_theme_font_size_override("font_size", 56)
	title.modulate = Color(1.0, 0.85, 0.35)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "You vanquished the final boss and conquered the run."
	subtitle.add_theme_font_size_override("font_size", 30 if compact else 20)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var continue_btn := Button.new()
	continue_btn.text = "Return to your realm"
	continue_btn.custom_minimum_size = Vector2(380, 96) if compact else Vector2(300, 56)
	continue_btn.add_theme_font_size_override("font_size", 32 if compact else 22)
	continue_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	continue_btn.pressed.connect(_on_continue)
	vbox.add_child(continue_btn)


func _on_continue() -> void:
	GameData.end_run()
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")
