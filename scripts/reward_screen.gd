extends Control


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.06, 0.1)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 40)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Victory!  Choose a Reward"
	title.add_theme_font_size_override("font_size", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 32)
	card_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(card_row)

	var pool: Array[String] = []
	if GameData.current_encounter != null:
		pool = GameData.current_encounter.reward_pool

	for id: String in pool:
		var data := CardData.get_card(id)
		if data == null:
			continue
		var inst := CardInstance.from_data(data)
		var ui := CardUI.create(inst)
		ui.custom_minimum_size = Vector2(160, 210)
		ui.pressed.connect(func(): _pick_card(id))
		card_row.add_child(ui)

	var skip_btn := Button.new()
	skip_btn.text = "Skip Reward"
	skip_btn.add_theme_font_size_override("font_size", 18)
	skip_btn.custom_minimum_size = Vector2(180, 0)
	skip_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	skip_btn.pressed.connect(_skip)
	vbox.add_child(skip_btn)


func _pick_card(id: String) -> void:
	GameData.current_run.deck.append(id)
	_finish()


func _skip() -> void:
	_finish()


func _finish() -> void:
	GameData.save_run()
	GameData.current_encounter = null
	get_tree().change_scene_to_file("res://scenes/map.tscn")
