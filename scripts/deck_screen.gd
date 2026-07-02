extends Control

# Deck management (reached from the hub's "Decks" button). Left: the profile's owned decks
# (one per unlocked King by default); click one to preview its full card list on the right.
# From the preview you can mark a deck active (used to pre-pick at Embark) or open the
# detail "View Deck" screen. Creating a deck picks an unlocked King and seeds its
# composition. Card-content editing (add/remove from a collection) is a later layer.

var _deck_grid: FitGrid
var _king_picker: PanelContainer
var _previewed_id: String = ""

var _preview_title: Label
var _preview_grid: FitGrid
var _set_active_btn: Button
var _view_btn: Button
var _edit_btn: Button
var _reset_btn: Button
var _delete_btn: Button
var _confirm_reset: ConfirmationDialog
var _confirm_delete: ConfirmationDialog
var _compact := false


func _ready() -> void:
	# Reached without a selected save (e.g. stale direct load) — bounce to save select.
	if GameData.current_profile == null or GameData.current_slot < 0:
		Nav.goto.call_deferred("res://scenes/game_slots.tscn")
		return
	_compact = UIScale.is_compact()
	_previewed_id = GameData.current_profile.selected_deck_id
	_build_ui()
	_rebuild()


func get_chrome() -> Dictionary:
	return {"title": "Decks", "exit": func(): Nav.goto("res://scenes/game_world.tscn"),
		"show_footer": true}


func _build_ui() -> void:
	# ── Body: deck grid (fills, no scroll) + preview panel (right), split by ratio ──
	var body := HBoxContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	body.add_theme_constant_override("separation", 24)
	add_child(body)

	body.add_child(_build_deck_grid_pane())
	body.add_child(_build_preview_pane())

	_build_king_picker()

	_confirm_reset = ConfirmationDialog.new()
	_confirm_reset.title = "Reset deck"
	_confirm_reset.confirmed.connect(_do_reset)
	add_child(_confirm_reset)

	_confirm_delete = ConfirmationDialog.new()
	_confirm_delete.title = "Delete deck"
	_confirm_delete.confirmed.connect(_do_delete)
	add_child(_confirm_delete)


func _build_deck_grid_pane() -> Control:
	# Every deck shown at once as a grid that sizes itself to fit — you never scroll through decks.
	# Each deck is its King's card (already card-shaped, so FitGrid handles it); + New is a tile too.
	_deck_grid = FitGrid.new()
	_deck_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_deck_grid.size_flags_vertical = SIZE_EXPAND_FILL
	_deck_grid.size_flags_stretch_ratio = 1.7
	return _deck_grid


func _build_preview_pane() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.size_flags_vertical = SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.0
	var style := StyleBoxFlat.new()
	style.bg_color = ScreenUI.SURFACE_COLOR
	style.border_color = ScreenUI.SURFACE_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", style)
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	pad.add_child(col)

	_preview_title = Label.new()
	_preview_title.add_theme_font_size_override("font_size", 34 if _compact else 28)
	col.add_child(_preview_title)

	# The whole deck always fits this pane — FitGrid sizes the cards to fill it, no scrolling.
	_preview_grid = FitGrid.new()
	_preview_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_preview_grid.size_flags_vertical = SIZE_EXPAND_FILL
	col.add_child(_preview_grid)

	# Two-column grid of chunky, full-width action buttons (no tiny floating chips).
	var actions := GridContainer.new()
	actions.columns = 2
	actions.add_theme_constant_override("h_separation", 16)
	actions.add_theme_constant_override("v_separation", 16)
	col.add_child(actions)

	_set_active_btn = _make_action_button("", _on_set_active, ScreenUI.CHROME_NEUTRAL)
	actions.add_child(_set_active_btn)
	_view_btn = _make_action_button("View Deck →", _on_view_deck, ScreenUI.CHROME_NEUTRAL)
	actions.add_child(_view_btn)
	_edit_btn = _make_action_button("Edit Deck →", _on_edit_deck, ScreenUI.CHROME_NEUTRAL)
	actions.add_child(_edit_btn)
	_reset_btn = _make_action_button("Reset", _on_reset, ScreenUI.CHROME_DANGER)
	actions.add_child(_reset_btn)
	_delete_btn = _make_action_button("Delete", _on_delete, ScreenUI.CHROME_DANGER)
	actions.add_child(_delete_btn)
	return panel


func _make_action_button(text: String, handler: Callable, color: Color) -> Button:
	var btn := ScreenUI.action_button(text, handler,
		Vector2(0, 120) if _compact else Vector2(0, 72), 32 if _compact else 24, color)
	btn.size_flags_horizontal = SIZE_EXPAND_FILL
	return btn


# An inline overlay listing the unlocked Kings; choosing one seeds a new deck for it.
func _build_king_picker() -> void:
	_king_picker = PanelContainer.new()
	_king_picker.set_anchors_and_offsets_preset(PRESET_CENTER)
	_king_picker.visible = false
	add_child(_king_picker)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 20)
	pad.add_child(box)
	_king_picker.add_child(pad)

	var prompt := Label.new()
	prompt.text = "New deck for which King?"
	prompt.add_theme_font_size_override("font_size", 28 if _compact else 18)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(prompt)

	for king_id: String in GameData.current_profile.unlocked_kings:
		var king := CardData.get_card(king_id)
		var id := king_id
		var btn := ScreenUI.action_button(king.display_name if king != null else king_id,
			func(): _create_deck(id), Vector2(360, 72) if _compact else Vector2(240, 40),
			26 if _compact else 16, ScreenUI.CHROME_NEUTRAL)
		box.add_child(btn)

	var cancel := ScreenUI.action_button("Cancel", func(): _king_picker.visible = false,
		Vector2(0, 64) if _compact else Vector2.ZERO, 22 if _compact else 14, ScreenUI.CHROME_NEUTRAL)
	box.add_child(cancel)


func _create_deck(king_id: String) -> void:
	var deck := GameData.current_profile.add_deck_for_king(king_id)
	if deck != null:
		GameData.save_profile()
		_previewed_id = deck.id   # preview the freshly-made deck
	_king_picker.visible = false
	_rebuild()


func _rebuild() -> void:
	var profile := GameData.current_profile
	# Per-king running index, so a King's 2nd+ deck reads "(2)".
	var king_seen: Dictionary = {}
	var tiles: Array[Control] = []
	for od: OwnedDeck in profile.decks:
		var n := int(king_seen.get(od.king_id, 0)) + 1
		king_seen[od.king_id] = n
		tiles.append(_make_deck_tile(od, n))
	tiles.append(_make_new_deck_tile())
	_deck_grid.set_cards(tiles)
	_update_preview()


# One deck = its King's card (FitGrid sizes it). Click selects it into the side preview; the active
# deck and a duplicate-ordinal suffix show as an overlaid badge. The previewed deck reads brighter.
func _make_deck_tile(od: OwnedDeck, ordinal: int) -> Control:
	var tile := Control.new()
	tile.mouse_filter = MOUSE_FILTER_IGNORE
	var id := od.id

	var king := CardData.get_card(od.king_id)
	if king != null:
		var card := CardUI.create(CardInstance.from_data(king))
		card.draggable = false
		card.custom_minimum_size = Vector2.ZERO
		card.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		card.pressed.connect(func(): _on_deck_clicked(id))
		if od.id == _previewed_id:
			card.set_selected(true)
		tile.add_child(card)

	var badge_text := ""
	if od.id == GameData.current_profile.selected_deck_id:
		badge_text = "✓ ACTIVE"
	if ordinal > 1:
		badge_text += ("   " if not badge_text.is_empty() else "") + "(%d)" % ordinal
	if not badge_text.is_empty():
		var badge := Label.new()
		badge.text = badge_text
		badge.add_theme_font_size_override("font_size", 18 if _compact else 13)
		badge.add_theme_color_override("font_color", Color(0.35, 1.0, 0.5))
		badge.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
		badge.add_theme_constant_override("outline_size", 5)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.mouse_filter = MOUSE_FILTER_IGNORE
		badge.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
		badge.offset_top = 4.0
		badge.offset_bottom = 32.0
		tile.add_child(badge)
	return tile


# A card-shaped "+ New Deck" tile sitting in the grid alongside the decks.
func _make_new_deck_tile() -> Control:
	var btn := ScreenUI.action_button("+\nNew Deck", func(): _king_picker.visible = true,
		Vector2.ZERO, 22 if _compact else 16, ScreenUI.CHROME_NEUTRAL)
	btn.size_flags_horizontal = SIZE_FILL
	btn.size_flags_vertical = SIZE_FILL
	return btn


func _on_deck_clicked(deck_id: String) -> void:
	_previewed_id = deck_id
	_rebuild()   # re-highlight rows + refresh preview


func _previewed_deck() -> OwnedDeck:
	for od: OwnedDeck in GameData.current_profile.decks:
		if od.id == _previewed_id:
			return od
	return GameData.current_profile.get_selected_deck()


func _previewed_ordinal(target: OwnedDeck) -> int:
	# This deck's per-king index, mirroring the list labels.
	var n := 0
	for od: OwnedDeck in GameData.current_profile.decks:
		if od.king_id == target.king_id:
			n += 1
		if od.id == target.id:
			return n
	return 1


func _update_preview() -> void:
	var od := _previewed_deck()
	if od == null:
		_preview_grid.set_cards([])
		_preview_title.text = ""
		_set_active_btn.disabled = true
		_view_btn.disabled = true
		_edit_btn.disabled = true
		_reset_btn.disabled = true
		_delete_btn.disabled = true
		return

	var is_active := od.id == GameData.current_profile.selected_deck_id
	_preview_title.text = "%s  ·  %d cards%s" % [
		DeckUI.deck_label(od, _previewed_ordinal(od)), od.cards.size(),
		"   (active)" if is_active else ""]
	_preview_grid.set_cards(DeckUI.deck_cards(od))

	_set_active_btn.text = "Active ✓" if is_active else "Set as Active"
	_set_active_btn.disabled = is_active
	_view_btn.disabled = false
	_edit_btn.disabled = false
	_reset_btn.disabled = false
	_delete_btn.disabled = not GameData.current_profile.can_delete_deck(od.id)


func _on_set_active() -> void:
	GameData.current_profile.select_deck(_previewed_id)
	GameData.save_profile()
	_rebuild()


func _on_view_deck() -> void:
	GameData.viewing_deck_id = _previewed_id
	Nav.goto("res://scenes/deck_view_screen.tscn")


func _on_edit_deck() -> void:
	GameData.editing_deck_id = _previewed_id
	Nav.goto("res://scenes/deck_build_screen.tscn")


func _on_reset() -> void:
	var od := _previewed_deck()
	if od == null:
		return
	_confirm_reset.dialog_text = "Reset \"%s\" to its default King template? Any customisation is lost." \
		% DeckUI.deck_label(od, _previewed_ordinal(od))
	_confirm_reset.popup_centered()


func _do_reset() -> void:
	var od := _previewed_deck()
	if od == null:
		return
	od.reset_to_template()
	GameData.save_profile()
	_rebuild()


func _on_delete() -> void:
	var od := _previewed_deck()
	if od == null or not GameData.current_profile.can_delete_deck(od.id):
		return
	_confirm_delete.dialog_text = "Delete \"%s\"? This can't be undone." \
		% DeckUI.deck_label(od, _previewed_ordinal(od))
	_confirm_delete.popup_centered()


func _do_delete() -> void:
	if GameData.current_profile.delete_deck(_previewed_id):
		GameData.save_profile()
		_previewed_id = GameData.current_profile.selected_deck_id
	_rebuild()
