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
	# Every owned deck shown at once as card-shaped tiles that fit the screen (no scroll),
	# mirroring the Decks screen so the chooser fills the canvas instead of stranding a small
	# cluster top-left.
	var grid := FitGrid.new()
	grid.size_flags_horizontal = SIZE_EXPAND_FILL
	grid.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(grid)

	var profile := GameData.current_profile
	var king_seen: Dictionary = {}
	var tiles: Array[Control] = []
	for od: OwnedDeck in profile.decks:
		var n := int(king_seen.get(od.king_id, 0)) + 1
		king_seen[od.king_id] = n
		tiles.append(_make_deck_card(od, n))
	grid.set_cards(tiles)


# A card-shaped tile: the King's card filling it, with the deck name + count on an overlay banner
# along the bottom. FitGrid sizes the whole tile, so it stays card-proportioned and fills the grid.
func _make_deck_card(od: OwnedDeck, ordinal: int) -> Control:
	var compact := UIScale.is_compact()
	var tile := Control.new()
	tile.mouse_filter = MOUSE_FILTER_IGNORE
	var id := od.id

	var king := CardData.get_card(od.king_id)
	if king != null:
		var card := CardUI.create(CardInstance.from_data(king))
		card.draggable = false
		card.custom_minimum_size = Vector2.ZERO
		card.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		card.pressed.connect(func(): _play(id))
		if od.id == GameData.current_profile.selected_deck_id:
			card.set_selected(true)
		tile.add_child(card)

	# Name + count banner pinned across the bottom of the card.
	var banner := VBoxContainer.new()
	banner.add_theme_constant_override("separation", 0)
	banner.mouse_filter = MOUSE_FILTER_IGNORE
	banner.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
	banner.offset_top = -68.0 if compact else -52.0
	banner.offset_bottom = -6.0

	var name_lbl := Label.new()
	name_lbl.text = DeckUI.deck_label(od, ordinal)
	name_lbl.add_theme_font_size_override("font_size", 28 if compact else 20)
	name_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	name_lbl.add_theme_constant_override("outline_size", 6)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	banner.add_child(name_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "%d cards" % od.cards.size()
	count_lbl.add_theme_font_size_override("font_size", 22 if compact else 16)
	count_lbl.add_theme_color_override("font_color", Color(0.8, 0.82, 0.9))
	count_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	count_lbl.add_theme_constant_override("outline_size", 5)
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	banner.add_child(count_lbl)

	tile.add_child(banner)
	return tile


func _play(deck_id: String) -> void:
	GameData.current_profile.select_deck(deck_id)
	GameData.save_profile()
	GameData.start_new_run()
	get_tree().change_scene_to_file("res://scenes/map.tscn")
