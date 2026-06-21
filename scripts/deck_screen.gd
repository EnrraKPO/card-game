extends Control

# Deck management (reached from the hub's "Decks" button). Left: the profile's owned decks
# (one per unlocked King by default); click one to preview its full card list on the right.
# From the preview you can mark a deck active (used to pre-pick at Embark) or open the
# detail "View Deck" screen. Creating a deck picks an unlocked King and seeds its
# composition. Card-content editing (add/remove from a collection) is a later layer.

var _list: VBoxContainer
var _king_picker: PanelContainer
var _previewed_id: String = ""

var _preview_title: Label
var _preview_body: VBoxContainer
var _set_active_btn: Button
var _view_btn: Button
var _edit_btn: Button
var _reset_btn: Button
var _delete_btn: Button
var _confirm_reset: ConfirmationDialog
var _confirm_delete: ConfirmationDialog
var _compact := false


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# Reached without a selected save (e.g. stale direct load) — bounce to save select.
	if GameData.current_profile == null or GameData.current_slot < 0:
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return
	_compact = UIScale.is_compact()
	_previewed_id = GameData.current_profile.selected_deck_id
	_build_ui()
	_rebuild()


func _build_ui() -> void:
	var s := ScreenUI.scaffold(self, "Decks")
	var root: VBoxContainer = s.root
	s.header.add_child(ScreenUI.nav_button("Back  ",
		func(): get_tree().change_scene_to_file("res://scenes/game_world.tscn")))

	# ── Body: deck list (left) + preview (right) ──────────────────────────────────
	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	body.add_child(_build_list_pane())
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


func _build_list_pane() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 520.0 if _compact else 440.0
	col.add_theme_constant_override("separation", 10)

	var new_btn := Button.new()
	new_btn.text = "+ New Deck"
	new_btn.custom_minimum_size = Vector2(0, 72 if _compact else 44)
	new_btn.add_theme_font_size_override("font_size", 26 if _compact else 17)
	new_btn.pressed.connect(func(): _king_picker.visible = true)
	var new_pad := MarginContainer.new()
	for side in ["left", "right", "top"]:
		new_pad.add_theme_constant_override("margin_" + side, 16)
	new_pad.add_child(new_btn)
	col.add_child(new_pad)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var pad := MarginContainer.new()
	for side in ["left", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 16)
	pad.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(pad)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 14)
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	pad.add_child(_list)
	return col


func _build_preview_pane() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 16)
	panel.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	pad.add_child(col)

	_preview_title = Label.new()
	_preview_title.add_theme_font_size_override("font_size", 30 if _compact else 22)
	col.add_child(_preview_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_preview_body = VBoxContainer.new()
	_preview_body.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_preview_body)

	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 12)
	actions.add_theme_constant_override("v_separation", 10)
	actions.alignment = FlowContainer.ALIGNMENT_CENTER
	col.add_child(actions)
	_set_active_btn = Button.new()
	_set_active_btn.custom_minimum_size = Vector2(240, 76) if _compact else Vector2(160, 40)
	_set_active_btn.add_theme_font_size_override("font_size", 26 if _compact else 16)
	_set_active_btn.pressed.connect(_on_set_active)
	actions.add_child(_set_active_btn)
	_view_btn = Button.new()
	_view_btn.text = "View Deck →"
	_view_btn.custom_minimum_size = Vector2(240, 76) if _compact else Vector2(160, 40)
	_view_btn.add_theme_font_size_override("font_size", 26 if _compact else 16)
	_view_btn.pressed.connect(_on_view_deck)
	actions.add_child(_view_btn)

	_edit_btn = Button.new()
	_edit_btn.text = "Edit Deck →"
	_edit_btn.custom_minimum_size = Vector2(240, 76) if _compact else Vector2(160, 40)
	_edit_btn.add_theme_font_size_override("font_size", 26 if _compact else 16)
	_edit_btn.pressed.connect(_on_edit_deck)
	actions.add_child(_edit_btn)

	_reset_btn = Button.new()
	_reset_btn.text = "Reset"
	_reset_btn.custom_minimum_size = Vector2(240, 76) if _compact else Vector2(140, 40)
	_reset_btn.add_theme_font_size_override("font_size", 26 if _compact else 16)
	_reset_btn.pressed.connect(_on_reset)
	actions.add_child(_reset_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.custom_minimum_size = Vector2(240, 76) if _compact else Vector2(140, 40)
	_delete_btn.add_theme_font_size_override("font_size", 26 if _compact else 16)
	_delete_btn.add_theme_color_override("font_color", Color(0.95, 0.6, 0.55))
	_delete_btn.pressed.connect(_on_delete)
	actions.add_child(_delete_btn)
	return panel


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
		var btn := Button.new()
		btn.text = king.display_name if king != null else king_id
		btn.custom_minimum_size = Vector2(360, 72) if _compact else Vector2(240, 40)
		btn.add_theme_font_size_override("font_size", 26 if _compact else 16)
		var id := king_id
		btn.pressed.connect(func(): _create_deck(id))
		box.add_child(btn)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.add_theme_font_size_override("font_size", 22 if _compact else 14)
	cancel.custom_minimum_size = Vector2(0, 64) if _compact else Vector2.ZERO
	cancel.pressed.connect(func(): _king_picker.visible = false)
	box.add_child(cancel)


func _create_deck(king_id: String) -> void:
	var deck := GameData.current_profile.add_deck_for_king(king_id)
	if deck != null:
		GameData.save_profile()
		_previewed_id = deck.id   # preview the freshly-made deck
	_king_picker.visible = false
	_rebuild()


func _rebuild() -> void:
	for child in _list.get_children():
		child.queue_free()

	var profile := GameData.current_profile
	# Per-king running index, so a King's 2nd+ deck reads "Magma King (2)".
	var king_seen: Dictionary = {}
	for od: OwnedDeck in profile.decks:
		var n := int(king_seen.get(od.king_id, 0)) + 1
		king_seen[od.king_id] = n
		_list.add_child(_make_deck_row(od, n))
	_update_preview()


func _make_deck_row(od: OwnedDeck, ordinal: int) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	if od.id == _previewed_id:
		panel.modulate = Color(1.25, 1.3, 1.15)   # the deck currently shown in the preview
	var id := od.id

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	pad.add_child(row)

	# King card — large enough to read, hover for full detail, click to preview the deck.
	var thumb := DeckUI.king_thumbnail(od.king_id, 180 if _compact else 124, true)
	thumb.size_flags_vertical = SIZE_SHRINK_CENTER
	if thumb is CardUI:
		(thumb as CardUI).pressed.connect(func(): _on_deck_clicked(id))
	row.add_child(thumb)

	# The rest of the row is a flat click target so the whole row selects, not just the card.
	var info_btn := Button.new()
	info_btn.flat = true
	info_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	info_btn.size_flags_vertical = SIZE_EXPAND_FILL
	info_btn.pressed.connect(func(): _on_deck_clicked(id))
	row.add_child(info_btn)

	var info := VBoxContainer.new()
	info.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 4)
	info.mouse_filter = MOUSE_FILTER_IGNORE
	info_btn.add_child(info)

	var name_lbl := Label.new()
	var label := DeckUI.deck_label(od, ordinal)
	if od.id == GameData.current_profile.selected_deck_id:
		label += "   ✓ active"
	name_lbl.text = label
	name_lbl.add_theme_font_size_override("font_size", 28 if _compact else 19)
	name_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	info.add_child(name_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "%d cards" % od.cards.size()
	count_lbl.add_theme_font_size_override("font_size", 22 if _compact else 15)
	count_lbl.modulate = Color(0.7, 0.72, 0.8)
	count_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	info.add_child(count_lbl)

	return panel


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
	for child in _preview_body.get_children():
		child.queue_free()

	var od := _previewed_deck()
	if od == null:
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
	_preview_body.add_child(DeckUI.deck_grid(od, 4, 92))

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
	get_tree().change_scene_to_file("res://scenes/deck_view_screen.tscn")


func _on_edit_deck() -> void:
	GameData.editing_deck_id = _previewed_id
	get_tree().change_scene_to_file("res://scenes/deck_build_screen.tscn")


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
