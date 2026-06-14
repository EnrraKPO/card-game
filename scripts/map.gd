extends Control


func _ready() -> void:
	var run := GameData.current_run

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Act %d  —  Floor %d" % [run.act, run.floor]
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var stats := Label.new()
	stats.text = "HP: %d / %d     Gold: %d" % [run.health, run.max_health, run.gold]
	stats.add_theme_font_size_override("font_size", 18)
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(stats)

	var placeholder := Label.new()
	placeholder.text = "[Map coming soon]"
	placeholder.add_theme_font_size_override("font_size", 16)
	placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	placeholder.modulate = Color(1, 1, 1, 0.4)
	vbox.add_child(placeholder)

	var quit_btn := Button.new()
	quit_btn.text = "Save & Quit"
	quit_btn.add_theme_font_size_override("font_size", 13)
	quit_btn.anchor_left = 0.0
	quit_btn.anchor_top = 1.0
	quit_btn.anchor_right = 0.0
	quit_btn.anchor_bottom = 1.0
	quit_btn.offset_left = 16
	quit_btn.offset_top = -48
	quit_btn.offset_right = 130
	quit_btn.offset_bottom = -16
	quit_btn.pressed.connect(_on_quit_pressed)
	add_child(quit_btn)


func _on_quit_pressed() -> void:
	GameData.save_run()
	get_tree().change_scene_to_file("res://scenes/hello_screen.tscn")
