extends Control


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var compact := UIScale.is_compact()
	var card_size := Vector2(230, 302) if compact else Vector2(160, 210)

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
	title.add_theme_font_size_override("font_size", 48 if compact else 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var gold_gained: int = GameData.current_encounter.gold_reward if GameData.current_encounter != null else 0
	var gold_lbl := Label.new()
	gold_lbl.text = "+%d Gold" % gold_gained
	gold_lbl.add_theme_font_size_override("font_size", 30 if compact else 20)
	gold_lbl.modulate = Color(1.0, 0.85, 0.3)
	gold_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(gold_lbl)

	# Experience was banked at combat end (GameData.apply_encounter_rewards) — show it for feedback.
	var exp_gained: int = GameData.current_encounter.exp_reward if GameData.current_encounter != null else 0
	if exp_gained > 0:
		var exp_lbl := Label.new()
		exp_lbl.text = "+%d Experience" % exp_gained
		exp_lbl.add_theme_font_size_override("font_size", 30 if compact else 20)
		exp_lbl.modulate = Color(0.55, 0.8, 1.0)
		exp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(exp_lbl)

	# Crafting resources earned this fight (already banked at combat end — shown for feedback).
	var mats: Dictionary = GameData.current_encounter.material_rewards if GameData.current_encounter != null else {}
	for id: String in mats:
		var amt := int(mats[id])
		if amt <= 0:
			continue
		var mat_lbl := Label.new()
		# Elemental essence rewards also grant one of that element's card (see
		# GameData.apply_encounter_rewards) — note it so the deck addition isn't a surprise.
		if id in Materials.ELEMENTS:
			mat_lbl.text = "+%d %s   ·   +1 %s card" % [amt, Materials.display_name(id), Materials.short_name(id)]
		else:
			mat_lbl.text = "+%d %s" % [amt, Materials.display_name(id)]
		mat_lbl.add_theme_font_size_override("font_size", 28 if compact else 18)
		mat_lbl.modulate = Materials.color(id)
		mat_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(mat_lbl)

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
		ui.draggable = false
		ui.custom_minimum_size = card_size
		ui.pressed.connect(func(): _pick_card(id))
		card_row.add_child(ui)

	var skip_btn := Button.new()
	skip_btn.text = "Skip Reward"
	skip_btn.add_theme_font_size_override("font_size", 30 if compact else 18)
	skip_btn.custom_minimum_size = Vector2(260, 84) if compact else Vector2(180, 0)
	skip_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	skip_btn.pressed.connect(_skip)
	vbox.add_child(skip_btn)


func _pick_card(id: String) -> void:
	GameData.current_run.deck.append(DeckCard.make(id))
	_finish()


func _skip() -> void:
	_finish()


func _finish() -> void:
	# Gold + materials were already applied at combat end (GameData.apply_encounter_rewards);
	# here we only persist any card the player picked and leave.
	GameData.save_run()
	GameData.current_encounter = null
	get_tree().change_scene_to_file("res://scenes/map.tscn")
