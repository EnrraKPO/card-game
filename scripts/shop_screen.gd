extends Control

const OFFER_COUNT := 4
const REMOVE_COST := 50

# One entry per offered card. { "id": String, "data": CardData, "price": int,
# "ui": CardUI, "buy_btn": Button, "bought": bool }
var _offers: Array = []

# One entry per card slot in the current deck.
# { "id": String, "deck_idx": int, "data": CardData, "ui": CardUI }
var _deck_entries: Array = []
var _selected_idx: int = -1   # index into _deck_entries, -1 = none

var _deck_grid: GridContainer
var _gold_lbl: Label
var _remove_status_lbl: Label
var _remove_btn: Button
var _buy_row: HBoxContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_build_ui()
	_roll_offers()
	_rebuild_deck()


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.07, 0.07, 0.12)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# ── Header ─────────────────────────────────────────────────────────────────
	var header := PanelContainer.new()
	header.custom_minimum_size.y = 56.0
	root.add_child(header)

	var header_hbox := HBoxContainer.new()
	header.add_child(header_hbox)

	var title := Label.new()
	title.text = "  Shop"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_hbox.add_child(title)

	_gold_lbl = Label.new()
	_gold_lbl.add_theme_font_size_override("font_size", 18)
	_gold_lbl.modulate = Color(1.0, 0.85, 0.3)
	_gold_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_hbox.add_child(_gold_lbl)

	var leave_btn := Button.new()
	leave_btn.text = "Leave  "
	leave_btn.add_theme_font_size_override("font_size", 18)
	leave_btn.pressed.connect(_leave)
	header_hbox.add_child(leave_btn)

	# ── Body ───────────────────────────────────────────────────────────────────
	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	body.add_child(_build_buy_panel())
	body.add_child(VSeparator.new())
	body.add_child(_build_remove_panel())

	_refresh_gold_label()


# ── Buy panel ────────────────────────────────────────────────────────────────

func _build_buy_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 16)

	var label := Label.new()
	label.text = "  Buy Cards"
	label.add_theme_font_size_override("font_size", 18)
	panel.add_child(label)

	_buy_row = HBoxContainer.new()
	_buy_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_buy_row.size_flags_vertical = SIZE_EXPAND_FILL
	_buy_row.add_theme_constant_override("separation", 16)
	panel.add_child(_buy_row)

	for i in OFFER_COUNT:
		_buy_row.add_child(_make_offer_slot())

	return panel


func _make_offer_slot() -> Control:
	var slot := VBoxContainer.new()
	slot.custom_minimum_size = Vector2(150, 0)
	slot.add_theme_constant_override("separation", 8)
	return slot


func _roll_offers() -> void:
	var ids := CardData.random_non_kings(OFFER_COUNT)
	for i in ids.size():
		var data := CardData.get_card(ids[i])
		if data == null:
			continue
		var inst := CardInstance.from_data(data)
		var ui := CardUI.create(inst)
		ui.custom_minimum_size = Vector2(130, 170)
		ui.mouse_filter = MOUSE_FILTER_IGNORE

		var price := _price_for(data)
		var price_lbl := Label.new()
		price_lbl.text = "%d Gold" % price
		price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

		var buy_btn := Button.new()
		buy_btn.text = "Buy"

		var slot: VBoxContainer = _buy_row.get_child(i)
		slot.add_child(ui)
		slot.add_child(price_lbl)
		slot.add_child(buy_btn)

		var entry := {"id": ids[i], "data": data, "price": price, "buy_btn": buy_btn, "bought": false}
		_offers.append(entry)
		var entry_idx := _offers.size() - 1
		buy_btn.pressed.connect(func(): _on_buy_pressed(entry_idx))

	_update_buy_buttons()


func _price_for(card: CardData) -> int:
	return 30 + card.cost * 20


func _on_buy_pressed(entry_idx: int) -> void:
	var entry: Dictionary = _offers[entry_idx]
	if entry.bought or GameData.current_run.gold < entry.price:
		return
	GameData.current_run.gold -= entry.price
	GameData.current_run.deck.append(entry.id)
	GameData.save_run()
	entry.bought = true
	entry.buy_btn.text = "Sold"
	_update_buy_buttons()
	_refresh_gold_label()


func _update_buy_buttons() -> void:
	for entry: Dictionary in _offers:
		entry.buy_btn.disabled = entry.bought or GameData.current_run.gold < entry.price


# ── Remove panel ─────────────────────────────────────────────────────────────

func _build_remove_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size.x = 420.0
	panel.size_flags_vertical = SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = "  Remove a Card"
	label.add_theme_font_size_override("font_size", 18)
	panel.add_child(label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	panel.add_child(scroll)

	_deck_grid = GridContainer.new()
	_deck_grid.columns = 3
	_deck_grid.add_theme_constant_override("h_separation", 10)
	_deck_grid.add_theme_constant_override("v_separation", 10)
	_deck_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_deck_grid)

	_remove_status_lbl = Label.new()
	_remove_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(_remove_status_lbl)

	_remove_btn = Button.new()
	_remove_btn.text = "Remove (%d Gold)" % REMOVE_COST
	_remove_btn.disabled = true
	_remove_btn.pressed.connect(_apply_remove)
	panel.add_child(_remove_btn)

	return panel


func _rebuild_deck() -> void:
	for child in _deck_grid.get_children():
		child.queue_free()
	_deck_entries.clear()
	_selected_idx = -1

	var deck: Array = GameData.current_run.deck.duplicate()
	for i in deck.size():
		var id: String = deck[i]
		var data := CardData.get_card(id)
		if data == null:
			continue
		var inst := CardInstance.from_data(data)
		var ui   := CardUI.create(inst)
		ui.custom_minimum_size = Vector2(110, 145)

		var entry_idx := _deck_entries.size()
		_deck_entries.append({"id": id, "deck_idx": i, "data": data, "ui": ui})
		ui.pressed.connect(func(): _on_deck_card_pressed(entry_idx))

		_deck_grid.add_child(ui)

	_update_remove_panel()


func _on_deck_card_pressed(entry_idx: int) -> void:
	if _selected_idx == entry_idx:
		_deck_entries[entry_idx].ui.set_selected(false)
		_selected_idx = -1
	else:
		if _selected_idx >= 0:
			_deck_entries[_selected_idx].ui.set_selected(false)
		_selected_idx = entry_idx
		_deck_entries[entry_idx].ui.set_selected(true)
	_update_remove_panel()


func _update_remove_panel() -> void:
	if _selected_idx < 0:
		_remove_status_lbl.text = "Select a card to remove"
		_remove_btn.disabled = true
		return
	var card_name: String = _deck_entries[_selected_idx].data.display_name
	var can_afford: bool = GameData.current_run.gold >= REMOVE_COST
	_remove_status_lbl.text = "Remove %s?" % card_name
	if not can_afford:
		_remove_status_lbl.text += "  (not enough gold)"
	_remove_btn.disabled = not can_afford


func _apply_remove() -> void:
	if _selected_idx < 0 or GameData.current_run.gold < REMOVE_COST:
		return
	var deck_idx: int = _deck_entries[_selected_idx].deck_idx
	GameData.current_run.gold -= REMOVE_COST
	GameData.current_run.deck.remove_at(deck_idx)
	GameData.save_run()

	_refresh_gold_label()
	_update_buy_buttons()
	_rebuild_deck()


# ── Shared ───────────────────────────────────────────────────────────────────

func _refresh_gold_label() -> void:
	_gold_lbl.text = "  Gold: %d  " % GameData.current_run.gold


func _leave() -> void:
	get_tree().change_scene_to_file("res://scenes/map.tscn")
