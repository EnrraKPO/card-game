extends Control

# Read-only deck detail (reached from the Decks screen's "View Deck"). Shows every card in
# the chosen deck at full size. The deck is handed over via GameData.viewing_deck_id;
# editing (add/remove from a collection) is a separate, later layer.

func _ready() -> void:
	if GameData.current_profile == null or GameData.current_slot < 0:
		Nav.goto.call_deferred("res://scenes/game_slots.tscn")
		return
	_build_ui()


func _deck() -> OwnedDeck:
	for od: OwnedDeck in GameData.current_profile.decks:
		if od.id == GameData.viewing_deck_id:
			return od
	return GameData.current_profile.get_selected_deck()


func get_chrome() -> Dictionary:
	var od := _deck()
	var title := "Deck"
	if od != null:
		var king := CardData.get_card(od.king_id)
		var king_name: String = king.display_name if king != null else od.king_id
		title = "%s  ·  %d cards" % [king_name, od.cards.size()]
	return {"title": title, "exit": func(): Nav.goto("res://scenes/deck_screen.tscn"),
		"show_footer": true}


func _build_ui() -> void:
	var od := _deck()

	# ── Card grid: the whole deck sized to fill the screen, never scrolled ─────────
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 24)
	add_child(pad)

	var grid := FitGrid.new()
	pad.add_child(grid)
	if od != null:
		grid.set_cards(DeckUI.deck_cards(od))
