extends Control

# One entry per card slot in the current deck.
# { "id": String, "deck_idx": int, "data": CardData, "ui": CardUI }
var _entries: Array = []
var _selected: Array = []   # indices into _entries, max 2
var _result_card: CardData = null
# The deck entry that will be added on combine — carries charms inherited from both
# parents (charms are a component layer, so they survive the merge).
var _result_deck_card: DeckCard = null

# Must match the CardUI root custom_minimum_size in scenes/card_ui.tscn so the
# deck grid and combine slots scale with the cards.
const CARD_SIZE := Vector2(160, 210)

var _deck_grid: GridContainer
var _slot_a: Control
var _slot_b: Control
var _slot_result: Control
var _status_lbl: Label
var _combine_btn: Button
var _charm_row: HBoxContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_build_ui()
	_rebuild_deck()
	_rebuild_charms()


func _build_ui() -> void:
	var s := ScreenUI.scaffold(self, "Forge — Combine Cards")
	var root: VBoxContainer = s.root
	s.header.add_child(ScreenUI.nav_button("Leave  ", _leave))

	# ── Body ───────────────────────────────────────────────────────────────────
	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	# Left: scrollable deck grid
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	body.add_child(scroll)

	_deck_grid = GridContainer.new()
	_deck_grid.columns = 4
	_deck_grid.add_theme_constant_override("h_separation", 12)
	_deck_grid.add_theme_constant_override("v_separation", 12)
	_deck_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_deck_grid)

	body.add_child(VSeparator.new())

	# Right: combination panel
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 620.0
	right.size_flags_vertical    = SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 0)
	body.add_child(right)

	var right_center := CenterContainer.new()
	right_center.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(right_center)

	var panel_vbox := VBoxContainer.new()
	panel_vbox.add_theme_constant_override("separation", 24)
	right_center.add_child(panel_vbox)

	var instruction := Label.new()
	instruction.text = "Combine two cards, or enchant one card with a charm"
	instruction.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	instruction.add_theme_font_size_override("font_size", 18)
	panel_vbox.add_child(instruction)

	# Card slots
	var slots_row := HBoxContainer.new()
	slots_row.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_row.add_theme_constant_override("separation", 12)
	panel_vbox.add_child(slots_row)

	_slot_a = _make_card_slot()
	slots_row.add_child(_slot_a)

	var plus_lbl := Label.new()
	plus_lbl.text = "+"
	plus_lbl.add_theme_font_size_override("font_size", 32)
	plus_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slots_row.add_child(plus_lbl)

	_slot_b = _make_card_slot()
	slots_row.add_child(_slot_b)

	var arrow_lbl := Label.new()
	arrow_lbl.text = "→"
	arrow_lbl.add_theme_font_size_override("font_size", 32)
	arrow_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slots_row.add_child(arrow_lbl)

	_slot_result = _make_card_slot()
	slots_row.add_child(_slot_result)

	# Status
	_status_lbl = Label.new()
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.add_theme_font_size_override("font_size", 15)
	panel_vbox.add_child(_status_lbl)

	# Action buttons
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	panel_vbox.add_child(btn_row)

	_combine_btn = Button.new()
	_combine_btn.text = "Combine"
	_combine_btn.add_theme_font_size_override("font_size", 18)
	_combine_btn.custom_minimum_size = Vector2(140, 0)
	_combine_btn.disabled = true
	_combine_btn.pressed.connect(_apply_combine)
	btn_row.add_child(_combine_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.add_theme_font_size_override("font_size", 18)
	clear_btn.custom_minimum_size = Vector2(100, 0)
	clear_btn.pressed.connect(_clear_selection)
	btn_row.add_child(clear_btn)

	# ── Charm inventory ──────────────────────────────────────────────────────────
	panel_vbox.add_child(HSeparator.new())

	var charm_label := Label.new()
	charm_label.text = "Charms  (select one card, then a charm to enchant it)"
	charm_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	charm_label.add_theme_font_size_override("font_size", 15)
	charm_label.modulate = Color(0.75, 0.75, 0.85)
	panel_vbox.add_child(charm_label)

	_charm_row = HBoxContainer.new()
	_charm_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_charm_row.add_theme_constant_override("separation", 10)
	panel_vbox.add_child(_charm_row)


func _make_card_slot() -> Control:
	var slot := Control.new()
	slot.custom_minimum_size = CARD_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.18)
	style.set_border_width_all(1)
	style.border_color = Color(0.3, 0.3, 0.45)
	style.set_corner_radius_all(6)
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", style)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	slot.add_child(bg)
	return slot


# ── Deck display ────────────────────────────────────────────────────────────────

func _rebuild_deck() -> void:
	for child in _deck_grid.get_children():
		child.queue_free()
	_entries.clear()
	_selected.clear()
	_result_card = null
	_update_panel()

	var deck: Array = GameData.current_run.deck.duplicate()
	for i in deck.size():
		var dc: DeckCard = deck[i]
		var data := CardData.get_card(dc.id)
		if data == null:
			continue
		var inst := dc.make_instance()
		var ui   := CardUI.create(inst)
		ui.custom_minimum_size = CARD_SIZE

		var combinable := data.elements.size() > 0 or data.chess_pieces.size() > 0
		if not combinable:
			ui.modulate = Color(1, 1, 1, 0.35)

		var entry_idx := _entries.size()
		_entries.append({ "card": dc, "deck_idx": i, "data": data, "ui": ui })

		if combinable:
			ui.pressed.connect(func(): _on_card_pressed(entry_idx))

		_deck_grid.add_child(ui)


# ── Selection ──────────────────────────────────────────────────────────────────

func _on_card_pressed(entry_idx: int) -> void:
	if entry_idx in _selected:
		_selected.erase(entry_idx)
		_entries[entry_idx].ui.set_selected(false)
		_update_panel()
		return
	if _selected.size() >= 2:
		return
	_selected.append(entry_idx)
	_entries[entry_idx].ui.set_selected(true)
	_update_panel()


func _clear_selection() -> void:
	for idx in _selected:
		_entries[idx].ui.set_selected(false)
	_selected.clear()
	_update_panel()


# ── Combination panel ──────────────────────────────────────────────────────────

func _update_panel() -> void:
	_clear_slot(_slot_a)
	_clear_slot(_slot_b)
	_clear_slot(_slot_result)
	_result_card    = null
	_result_deck_card = null
	_combine_btn.disabled = true
	_status_lbl.modulate  = Color(0.65, 0.65, 0.65)

	if _selected.is_empty():
		_status_lbl.text = "Pick two cards from your deck"
		return

	var data_a: CardData = _entries[_selected[0]].data
	_fill_slot(_slot_a, _entries[_selected[0]].card.make_instance())

	if _selected.size() < 2:
		_status_lbl.text = "Pick one more card"
		return

	var data_b: CardData = _entries[_selected[1]].data
	_fill_slot(_slot_b, _entries[_selected[1]].card.make_instance())

	if not CardData.can_combine(data_a, data_b):
		_status_lbl.text    = "These cards exceed the combination limit (2 elements + 2 chess pieces)"
		_status_lbl.modulate = Color(1.0, 0.4, 0.4)
		return

	_result_card = CardData.combine(data_a, data_b)
	# Charms are a component layer: the result inherits every charm from both parents that
	# can still attach to it (incompatible ones — e.g. a unit charm on a spell result — are
	# dropped). Stat/effect overrides are NOT carried; the result is a fresh base card.
	_result_deck_card = DeckCard.make(_result_card.id)
	for charm_id: String in _merged_parent_charms():
		_result_deck_card.add_charm(charm_id)
	# Preview the actual result entry (charm pips + baked charm stats) via make_instance.
	_fill_slot(_slot_result, _result_deck_card.make_instance())
	_combine_btn.disabled = false
	_status_lbl.text    = "Result: %s" % _result_card.display_name
	_status_lbl.modulate = Color(0.4, 1.0, 0.55)


# Union of both selected parents' charms that are still valid on the combined result.
func _merged_parent_charms() -> Array:
	var out: Array = []
	for sel in _selected:
		var dc: DeckCard = _entries[sel].card
		for charm_id: String in dc.charms:
			var charm := CharmData.get_charm(charm_id)
			if charm != null and charm.can_attach_to(_result_card) and charm_id not in out:
				out.append(charm_id)
	return out


func _fill_slot(slot: Control, inst: CardInstance) -> void:
	_clear_slot(slot)
	var ui := CardUI.create(inst)
	ui.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	ui.mouse_filter = MOUSE_FILTER_IGNORE
	slot.add_child(ui)


func _clear_slot(slot: Control) -> void:
	for child in slot.get_children():
		if child is CardUI:
			child.queue_free()


# ── Charm inventory + application ────────────────────────────────────────────────

# One clickable chip per owned charm id (with a ×N count), built from RunData.charms.
func _rebuild_charms() -> void:
	for child in _charm_row.get_children():
		child.queue_free()

	var counts: Dictionary = {}
	for charm_id: String in GameData.current_run.charms:
		counts[charm_id] = int(counts.get(charm_id, 0)) + 1

	if counts.is_empty():
		var empty := Label.new()
		empty.text = "(no charms)"
		empty.add_theme_font_size_override("font_size", 14)
		empty.modulate = Color(0.6, 0.6, 0.65)
		_charm_row.add_child(empty)
		return

	for charm_id: String in counts:
		_charm_row.add_child(_make_charm_chip(charm_id, counts[charm_id]))


func _make_charm_chip(charm_id: String, count: int) -> Button:
	var charm := CharmData.get_charm(charm_id)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(56, 56)
	btn.add_theme_font_size_override("font_size", 20)
	btn.text = charm.letter if charm != null else "✦"
	if count > 1:
		btn.text += " ×%d" % count
	if charm != null:
		btn.modulate = charm.color.lightened(0.15)
		btn.tooltip_text = "%s — %s" % [charm.display_name, charm.description]
	btn.pressed.connect(func(): _try_apply_charm(charm_id))
	return btn


func _try_apply_charm(charm_id: String) -> void:
	if _selected.size() != 1:
		_set_status("Select exactly one card to enchant.", Color(1.0, 0.5, 0.4))
		return
	var dc: DeckCard = _entries[_selected[0]].card
	var data: CardData = _entries[_selected[0]].data
	var charm := CharmData.get_charm(charm_id)
	if charm == null:
		return
	if not charm.can_attach_to(data):
		_set_status("%s can't bear the %s charm." % [data.display_name, charm.display_name], Color(1.0, 0.4, 0.4))
		return
	if charm_id in dc.charms:
		_set_status("%s already bears the %s charm." % [data.display_name, charm.display_name], Color(1.0, 0.6, 0.3))
		return

	dc.add_charm(charm_id)
	GameData.current_run.charms.erase(charm_id)
	GameData.save_run()
	_rebuild_deck()      # clears selection + redraws the now-enchanted card
	_rebuild_charms()
	_set_status("Enchanted %s with %s!" % [data.display_name, charm.display_name], Color(0.4, 1.0, 0.55))


func _set_status(text: String, color: Color) -> void:
	_status_lbl.text = text
	_status_lbl.modulate = color


# ── Apply ──────────────────────────────────────────────────────────────────────

func _apply_combine() -> void:
	if _result_card == null or _selected.size() < 2:
		return

	# Remove source cards highest-index-first to avoid index shifting.
	var deck_indices := [
		_entries[_selected[0]].deck_idx,
		_entries[_selected[1]].deck_idx,
	]
	deck_indices.sort()
	for i in range(deck_indices.size() - 1, -1, -1):
		GameData.current_run.deck.remove_at(deck_indices[i])

	# The result base is fresh (overrides consumed), but it carries the parents' charms.
	GameData.current_run.deck.append(_result_deck_card)
	GameData.save_run()

	_rebuild_deck()


func _leave() -> void:
	get_tree().change_scene_to_file("res://scenes/map.tscn")
