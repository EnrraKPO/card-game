extends Control

# Shown when the King falls — the run is lost. The run has already been ended by combat
# (meta-progression kept); this is the "you lost" beat before returning to the hub.

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.10, 0.05, 0.06)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 32)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Run Over"
	title.add_theme_font_size_override("font_size", 56)
	title.modulate = Color(0.9, 0.35, 0.35)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Your King has fallen. The run ends here."
	subtitle.add_theme_font_size_override("font_size", 20)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var continue_btn := Button.new()
	continue_btn.text = "Return to your realm"
	continue_btn.custom_minimum_size = Vector2(300, 56)
	continue_btn.add_theme_font_size_override("font_size", 22)
	continue_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	continue_btn.pressed.connect(_on_continue)
	vbox.add_child(continue_btn)


func _on_continue() -> void:
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")
