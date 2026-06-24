extends Control

# Run-start deck selection (reached from the hub's Embark on a FRESH run — its own screen,
# not a popup). Shows each owned deck illustrated with its King's card; clicking one sets it
# as the run deck and launches. Cancel returns to the hub.

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	if GameData.current_profile == null or GameData.current_slot < 0:
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return
	_build_ui()


func _build_ui() -> void:
	var s := ScreenUI.scaffold(self, "Choose a Deck for This Run")
	var root: VBoxContainer = s.root
	ScreenUI.attach_exits(
		func(): get_tree().change_scene_to_file("res://scenes/game_world.tscn"), s.header, s.footer)

	# ── Deck grid ────────────────────────────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var center := MarginContainer.new()
	center.size_flags_horizontal = SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		center.add_theme_constant_override("margin_" + side, 24)
	scroll.add_child(center)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 18)
	center.add_child(grid)

	var profile := GameData.current_profile
	var king_seen: Dictionary = {}
	for od: OwnedDeck in profile.decks:
		var n := int(king_seen.get(od.king_id, 0)) + 1
		king_seen[od.king_id] = n
		grid.add_child(_make_deck_card(od, n))


func _make_deck_card(od: OwnedDeck, ordinal: int) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(250, 380) if compact else Vector2(190, 296)
	if od.id == GameData.current_profile.selected_deck_id:
		btn.modulate = Color(1.2, 1.25, 1.1)   # pre-highlight the last-used deck
	var id := od.id
	btn.pressed.connect(func(): _play(id))

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 6)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = MOUSE_FILTER_IGNORE
	btn.add_child(box)

	var thumb := DeckUI.king_thumbnail(od.king_id, 200 if compact else 150)
	thumb.size_flags_horizontal = SIZE_SHRINK_CENTER
	box.add_child(thumb)

	var name_lbl := Label.new()
	name_lbl.text = DeckUI.deck_label(od, ordinal)
	name_lbl.add_theme_font_size_override("font_size", 26 if compact else 17)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(name_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "%d cards" % od.cards.size()
	count_lbl.add_theme_font_size_override("font_size", 20 if compact else 14)
	count_lbl.modulate = Color(0.7, 0.72, 0.8)
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(count_lbl)

	return btn


func _play(deck_id: String) -> void:
	GameData.current_profile.select_deck(deck_id)
	GameData.save_profile()
	GameData.start_new_run()
	get_tree().change_scene_to_file("res://scenes/map.tscn")
