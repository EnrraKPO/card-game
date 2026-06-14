extends Control


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Select Save Slot"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	for i in GameData.SLOT_COUNT:
		var slot_data := GameData.get_slot_data(i)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(320, 64)
		btn.add_theme_font_size_override("font_size", 18)
		btn.text = "Slot %d  —  %s" % [i + 1, "Empty" if slot_data.is_empty() else "Continue"]
		var idx := i
		btn.pressed.connect(func(): _on_slot_selected(idx))
		vbox.add_child(btn)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.anchor_left = 0.0
	back_btn.anchor_top = 1.0
	back_btn.anchor_right = 0.0
	back_btn.anchor_bottom = 1.0
	back_btn.offset_left = 16
	back_btn.offset_top = -48
	back_btn.offset_right = 110
	back_btn.offset_bottom = -16
	back_btn.pressed.connect(_on_back_pressed)
	add_child(back_btn)


func _on_slot_selected(slot: int) -> void:
	if GameData.get_slot_data(slot).is_empty():
		GameData.new_run(slot)
	else:
		GameData.load_run(slot)
	get_tree().change_scene_to_file("res://scenes/map.tscn")


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/hello_screen.tscn")
