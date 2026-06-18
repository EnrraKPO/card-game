extends Control

# The selected save's hub ("game world"): surfaces that slot's meta-progression and
# launches its single run — Continue if one's in progress, otherwise start fresh.
# Kings / Decks / Unlocks are disabled placeholders until those features land.

var _confirm_abandon: ConfirmationDialog


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# Reached without a selected save (e.g. a stale direct load) — bounce to save select.
	if GameData.current_profile == null or GameData.current_slot < 0:
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.07, 0.11)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 28)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "%s's Realm" % GameData.username
	title.add_theme_font_size_override("font_size", 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(_build_loadout_panel())

	# Meta panels — disabled placeholders until their features land.
	var panels := HBoxContainer.new()
	panels.alignment = BoxContainer.ALIGNMENT_CENTER
	panels.add_theme_constant_override("separation", 16)
	vbox.add_child(panels)
	panels.add_child(_panel_button("Kings"))
	panels.add_child(_panel_button("Decks"))
	panels.add_child(_panel_button("Unlocks"))

	var has_run := GameData.slot_has_run(GameData.current_slot)

	var embark := Button.new()
	embark.text = "Continue Run" if has_run else "Embark"
	embark.custom_minimum_size = Vector2(260, 60)
	embark.add_theme_font_size_override("font_size", 26)
	embark.size_flags_horizontal = SIZE_SHRINK_CENTER
	embark.pressed.connect(_on_embark)
	vbox.add_child(embark)

	if has_run:
		var abandon := Button.new()
		abandon.text = "Abandon run"
		abandon.add_theme_font_size_override("font_size", 14)
		abandon.size_flags_horizontal = SIZE_SHRINK_CENTER
		abandon.pressed.connect(func(): _confirm_abandon.popup_centered())
		vbox.add_child(abandon)

	var back_btn := Button.new()
	back_btn.text = "Back to saves"
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.set_anchors_and_offsets_preset(PRESET_BOTTOM_LEFT)
	back_btn.offset_left = 16
	back_btn.offset_top = -48
	back_btn.offset_right = 150
	back_btn.offset_bottom = -16
	back_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/game_slots.tscn"))
	add_child(back_btn)

	_confirm_abandon = ConfirmationDialog.new()
	_confirm_abandon.title = "Abandon run"
	_confirm_abandon.dialog_text = "Abandon the current run? Your meta-progression is kept, but the run is lost."
	_confirm_abandon.confirmed.connect(_on_abandon_confirmed)
	add_child(_confirm_abandon)


func _build_loadout_panel() -> Control:
	var profile := GameData.current_profile
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var deck := profile.get_selected_deck()
	var king := CardData.get_card(deck.king_id) if deck != null else null
	var king_name: String = king.display_name if king != null else profile.get_selected_king()
	_add_stat(box, "King", king_name)
	_add_stat(box, "Deck", "%d cards" % (deck.cards.size() if deck != null else 0))
	_add_stat(box, "Renown", str(profile.renown))
	return panel


func _add_stat(box: VBoxContainer, key: String, value: String) -> void:
	var lbl := Label.new()
	lbl.text = "  %s:  %s  " % [key, value]
	lbl.add_theme_font_size_override("font_size", 18)
	box.add_child(lbl)


func _panel_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(150, 52)
	btn.add_theme_font_size_override("font_size", 18)
	btn.disabled = true
	btn.tooltip_text = "Coming soon"
	return btn


func _on_embark() -> void:
	if GameData.slot_has_run(GameData.current_slot):
		GameData.load_run()
	else:
		GameData.start_new_run()
	get_tree().change_scene_to_file("res://scenes/map.tscn")


func _on_abandon_confirmed() -> void:
	GameData.end_run()
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")
