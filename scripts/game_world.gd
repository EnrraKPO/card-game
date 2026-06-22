extends Control

# The selected save's hub ("game world"): surfaces that slot's meta-progression and
# launches its single run — Continue if one's in progress, otherwise start fresh.
# The meta panels (Upgrades / Decks / Lab) each open their own screen.

var _confirm_abandon: ConfirmationDialog


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# Reached without a selected save (e.g. a stale direct load) — bounce to save select.
	if GameData.current_profile == null or GameData.current_slot < 0:
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return

	# Rebuild if the form factor flips (e.g. previewing mobile by resizing in the editor).
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)
	var compact := UIScale.is_compact()

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.07, 0.11)
	add_child(bg)

	# Desktop centres a compact column; compact fills the screen (minus margins) so the
	# touch controls are large and the space isn't wasted.
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 36 if compact else 28)
	if compact:
		var pad := MarginContainer.new()
		pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		for side in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + side, 56)
		add_child(pad)
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		pad.add_child(vbox)
	else:
		var center := CenterContainer.new()
		center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		add_child(center)
		center.add_child(vbox)

	var title := Label.new()
	title.text = "%s's Realm" % GameData.username
	title.add_theme_font_size_override("font_size", 56 if compact else 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(_build_loadout_panel())

	# Meta panels — each opens its own meta-progression screen.
	var panels := HBoxContainer.new()
	panels.alignment = BoxContainer.ALIGNMENT_CENTER
	panels.add_theme_constant_override("separation", 16)
	vbox.add_child(panels)
	panels.add_child(_panel_button("Upgrades", "res://scenes/upgrades_screen.tscn", compact))
	panels.add_child(_panel_button("Decks", "res://scenes/deck_screen.tscn", compact))
	panels.add_child(_panel_button("Collection", "res://scenes/collection_screen.tscn", compact))
	panels.add_child(_panel_button("Lab", "res://scenes/lab_screen.tscn", compact))

	var has_run := GameData.slot_has_run(GameData.current_slot)

	var embark := Button.new()
	embark.text = "Continue Run" if has_run else "Embark"
	embark.add_theme_font_size_override("font_size", 30 if compact else 26)
	if compact:
		embark.custom_minimum_size = Vector2(0, 96)
		embark.size_flags_horizontal = SIZE_FILL
	else:
		embark.custom_minimum_size = Vector2(260, 60)
		embark.size_flags_horizontal = SIZE_SHRINK_CENTER
	embark.pressed.connect(_on_embark)
	vbox.add_child(embark)

	if has_run:
		var abandon := Button.new()
		abandon.text = "Abandon run"
		abandon.add_theme_font_size_override("font_size", 18 if compact else 14)
		abandon.custom_minimum_size = Vector2(0, 56 if compact else 0)
		abandon.size_flags_horizontal = SIZE_FILL if compact else SIZE_SHRINK_CENTER
		abandon.pressed.connect(func(): _confirm_abandon.popup_centered())
		vbox.add_child(abandon)

	var back_btn := Button.new()
	back_btn.text = "Back to saves"
	back_btn.add_theme_font_size_override("font_size", 18 if compact else 13)
	back_btn.set_anchors_and_offsets_preset(PRESET_BOTTOM_LEFT)
	back_btn.offset_left = 16
	back_btn.offset_top = -(64 if compact else 48)
	back_btn.offset_right = 220 if compact else 150
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
	var exp_pad := MarginContainer.new()
	exp_pad.add_theme_constant_override("margin_left", 8)
	exp_pad.add_theme_constant_override("margin_top", 4)
	exp_pad.add_theme_constant_override("margin_bottom", 4)
	exp_pad.add_child(ScreenUI.experience_bar(profile))
	box.add_child(exp_pad)
	# Crafting resources earned from runs (essences / King Pieces).
	for id: String in profile.materials.ids():
		var n := profile.materials.count(id)
		if n > 0:
			_add_stat(box, Materials.display_name(id), str(n))
	return panel


func _add_stat(box: VBoxContainer, key: String, value: String) -> void:
	var lbl := Label.new()
	lbl.text = "  %s:  %s  " % [key, value]
	lbl.add_theme_font_size_override("font_size", 18)
	box.add_child(lbl)


func _panel_button(label: String, scene_path: String = "", compact: bool = false) -> Button:
	var btn := Button.new()
	btn.text = label
	if compact:
		btn.custom_minimum_size = Vector2(0, 80)
		btn.size_flags_horizontal = SIZE_EXPAND_FILL   # spread across the row
		btn.add_theme_font_size_override("font_size", 22)
	else:
		btn.custom_minimum_size = Vector2(150, 52)
		btn.add_theme_font_size_override("font_size", 18)
	if scene_path.is_empty():
		btn.disabled = true
		btn.tooltip_text = "Coming soon"
	else:
		btn.pressed.connect(func(): get_tree().change_scene_to_file(scene_path))
	return btn


func _on_embark() -> void:
	# Continuing an in-progress run keeps its existing deck snapshot — no choice to make.
	# A fresh run goes through the deck-selection screen, which sets the run deck and launches.
	if GameData.slot_has_run(GameData.current_slot):
		GameData.load_run()
		get_tree().change_scene_to_file("res://scenes/map.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/deck_select_screen.tscn")


func _on_abandon_confirmed() -> void:
	GameData.end_run()
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")
