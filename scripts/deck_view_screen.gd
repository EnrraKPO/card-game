extends Control

# Read-only deck detail (reached from the Decks screen's "View Deck"). Shows every card in
# the chosen deck at full size. The deck is handed over via GameData.viewing_deck_id;
# editing (add/remove from a collection) is a separate, later layer.

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	if GameData.current_profile == null or GameData.current_slot < 0:
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return
	_build_ui()


func _deck() -> OwnedDeck:
	for od: OwnedDeck in GameData.current_profile.decks:
		if od.id == GameData.viewing_deck_id:
			return od
	return GameData.current_profile.get_selected_deck()


func _build_ui() -> void:
	var od := _deck()

	var title := "Deck"
	if od != null:
		var king := CardData.get_card(od.king_id)
		var king_name: String = king.display_name if king != null else od.king_id
		title = "%s  ·  %d cards" % [king_name, od.cards.size()]

	var s := ScreenUI.scaffold(self, title)
	var root: VBoxContainer = s.root
	ScreenUI.attach_exits(
		func(): get_tree().change_scene_to_file("res://scenes/deck_screen.tscn"), s.header, s.footer)

	# ── Card grid: the whole deck sized to fill the screen, never scrolled ─────────
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = SIZE_EXPAND_FILL
	pad.size_flags_vertical = SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 24)
	root.add_child(pad)

	var grid := FitGrid.new()
	pad.add_child(grid)
	if od != null:
		grid.set_cards(DeckUI.deck_cards(od))
