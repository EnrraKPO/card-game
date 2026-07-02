extends Control

# The shop's buy side is generic: it offers one labelled row per entry in SHOP_KINDS, each row's
# items sampled and rendered through the unified ItemKind/Grant layer (see ItemKinds). Adding a new
# purchasable item type is one row here — no bespoke offer/buy code. The remove-a-card panel on the
# right is unchanged.

const REMOVE_COST := 50

# Which item kinds the shop sells, in display order, with how many of each to offer.
const SHOP_KINDS := [
	{"kind": "card",  "count": 4, "label": "Buy Cards"},
	{"kind": "charm", "count": 3, "label": "Buy Charms"},
	{"kind": "relic", "count": 2, "label": "Buy Relics"},
]

# One entry per offered item: { "grant": Grant, "price": int, "buy_btn": Button, "bought": bool }
var _offers: Array = []

# One entry per card slot in the current deck.
# { "card": DeckCard, "deck_idx": int, "data": CardData, "ui": CardUI }
var _deck_entries: Array = []
var _selected_idx: int = -1   # index into _deck_entries, -1 = none

var _deck_grid: FitGrid
var _remove_status_lbl: Label
var _remove_btn: Button
var _compact := false


func _ready() -> void:
	_compact = UIScale.is_compact()
	_build_ui()
	_rebuild_deck()


func get_chrome() -> Dictionary:
	return {"title": "Shop", "exit": _leave, "fields": [ScreenUI.Field.EXP, ScreenUI.Field.GOLD],
		"show_footer": true}


func _build_ui() -> void:
	# ── Body ───────────────────────────────────────────────────────────────────
	var body := HBoxContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	body.add_theme_constant_override("separation", 24)
	add_child(body)

	var buy := _build_buy_panel()
	buy.size_flags_stretch_ratio = 2.0
	body.add_child(buy)
	body.add_child(VSeparator.new())
	var remove := _build_remove_panel()
	remove.size_flags_stretch_ratio = 1.0
	body.add_child(remove)


# ── Buy panel (generic over ItemKinds) ───────────────────────────────────────

func _build_buy_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 16)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 16)
	scroll.add_child(col)

	for entry: Dictionary in SHOP_KINDS:
		col.add_child(_build_kind_row(entry))

	_update_buy_buttons()
	return panel


# A labelled row of offers for one item kind, sampled fresh from the kind's pool.
func _build_kind_row(entry: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "  " + str(entry.get("label", ""))
	label.add_theme_font_size_override("font_size", 28 if _compact else 24)
	box.add_child(label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28 if _compact else 24)
	box.add_child(row)

	var kind_key := str(entry.get("kind", ""))
	var kind := ItemKinds.get_kind(kind_key)
	if kind == null:
		return box

	var ids := kind.offer_pool(int(entry.get("count", 0)), null)
	for id: String in ids:
		row.add_child(_make_offer_slot(Grant.make(kind_key, id)))
	if ids.is_empty():
		var none := Label.new()
		none.text = "  (sold out)"
		none.add_theme_color_override("font_color", Color("5a4a38"))
		row.add_child(none)
	return box


func _make_offer_slot(grant: Grant) -> Control:
	var slot := VBoxContainer.new()
	slot.custom_minimum_size = Vector2(220 if _compact else 190, 0)
	slot.add_theme_constant_override("separation", 10)
	slot.alignment = BoxContainer.ALIGNMENT_CENTER

	var ui := grant.make_ui()
	ui.size_flags_horizontal = SIZE_SHRINK_CENTER
	slot.add_child(ui)

	var name_lbl := Label.new()
	name_lbl.text = grant.display_name()
	name_lbl.add_theme_font_size_override("font_size", 20 if _compact else 18)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.custom_minimum_size.x = 180
	slot.add_child(name_lbl)

	var price := grant.price()
	var price_lbl := Label.new()
	price_lbl.text = "%d Gold" % price
	price_lbl.add_theme_font_size_override("font_size", 22 if _compact else 19)
	price_lbl.add_theme_color_override("font_color", Color("9c7a10"))
	price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot.add_child(price_lbl)

	var buy_btn := ScreenUI.action_button("Buy", Callable(),
		Vector2(0, 96) if _compact else Vector2(0, 64), 28 if _compact else 22,
		ScreenUI.CHROME_CONFIRM)
	buy_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	slot.add_child(buy_btn)

	var rec := {"grant": grant, "price": price, "buy_btn": buy_btn, "bought": false}
	_offers.append(rec)
	buy_btn.pressed.connect(func() -> void: _on_buy(rec))
	return slot


func _on_buy(rec: Dictionary) -> void:
	var grant: Grant = rec["grant"]
	if rec["bought"] or GameData.current_run.gold < rec["price"] or not grant.can_apply():
		return
	GameData.current_run.gold -= rec["price"]
	grant.apply()
	rec["bought"] = true
	_update_buy_buttons()


func _update_buy_buttons() -> void:
	for rec: Dictionary in _offers:
		var grant: Grant = rec["grant"]
		var affordable: bool = GameData.current_run.gold >= int(rec["price"])
		var grantable: bool = grant.can_apply()
		rec["buy_btn"].disabled = rec["bought"] or not affordable or not grantable
		if rec["bought"]:
			rec["buy_btn"].text = "Bought"
		elif not grantable:
			rec["buy_btn"].text = "Full"   # e.g. relic capacity reached
		else:
			rec["buy_btn"].text = "Buy"


# ── Remove panel ─────────────────────────────────────────────────────────────

func _build_remove_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.size_flags_vertical = SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 16)

	var label := Label.new()
	label.text = "  Remove a Card"
	label.add_theme_font_size_override("font_size", 28 if _compact else 24)
	panel.add_child(label)

	# The whole deck fits — FitGrid sizes the cards to fill, no scrolling.
	_deck_grid = FitGrid.new()
	_deck_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_deck_grid.size_flags_vertical   = SIZE_EXPAND_FILL
	panel.add_child(_deck_grid)

	_remove_status_lbl = Label.new()
	_remove_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_remove_status_lbl.add_theme_font_size_override("font_size", 26 if _compact else 22)
	panel.add_child(_remove_status_lbl)

	_remove_btn = ScreenUI.action_button("Remove (%d Gold)" % REMOVE_COST, _apply_remove,
		Vector2(0, 120) if _compact else Vector2(0, 84), 30 if _compact else 26,
		ScreenUI.CHROME_DANGER)
	_remove_btn.disabled = true
	_remove_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.add_child(_remove_btn)

	return panel


func _rebuild_deck() -> void:
	_deck_entries.clear()
	_selected_idx = -1

	var cards: Array = []
	var deck: Array = GameData.current_run.deck.duplicate()
	for i in deck.size():
		var dc: DeckCard = deck[i]
		var data := CardData.get_card(dc.id)
		if data == null:
			continue
		var inst := dc.make_instance()
		var ui   := CardUI.create(inst)

		var entry_idx := _deck_entries.size()
		_deck_entries.append({"card": dc, "deck_idx": i, "data": data, "ui": ui})
		ui.pressed.connect(func(): _on_deck_card_pressed(entry_idx))

		cards.append(ui)

	_deck_grid.set_cards(cards)
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

	_update_buy_buttons()
	_rebuild_deck()


# ── Shared ───────────────────────────────────────────────────────────────────

func _leave() -> void:
	Nav.goto("res://scenes/map.tscn")
