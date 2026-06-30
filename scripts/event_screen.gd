extends Control

# A "?" site: pay gold to permanently raise one chosen deck card by +1 in the stat
# this node rolled (GameData.current_event_attr, set by NodeKindEvent). One upgrade
# per visit. Spells can't be placed as units, so only units are eligible.
const EVENT_COST := 40

var _attr: String = "attack"
var _entries: Array = []      # { "card": DeckCard, "deck_idx": int, "ui": CardUI }
var _selected_idx: int = -1
var _done: bool = false
var _compact := false

var _deck_grid: FitGrid
var _gold_lbl: Label
var _status_lbl: Label
var _upgrade_btn: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_attr = GameData.current_event_attr
	if _attr.is_empty():
		_attr = DeckCard.UPGRADABLE[0]
	_build_ui()
	_rebuild_deck()


func _build_ui() -> void:
	_compact = UIScale.is_compact()
	var root := ScreenUI.frame(self, "Event", _leave)
	root.add_theme_constant_override("separation", 16)

	var title := Label.new()
	title.text = "A Wandering Trainer"
	title.add_theme_font_size_override("font_size", 52 if _compact else 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var blurb := Label.new()
	blurb.text = "Offers to permanently raise one unit's %s by +1, for %d gold." \
		% [DeckCard.attr_label(_attr), EVENT_COST]
	blurb.add_theme_font_size_override("font_size", 26 if _compact else 22)
	blurb.modulate = Color(0.85, 0.8, 0.6)
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(blurb)

	_gold_lbl = Label.new()
	_gold_lbl.add_theme_font_size_override("font_size", 28 if _compact else 24)
	_gold_lbl.modulate = Color(1.0, 0.85, 0.3)
	_gold_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_gold_lbl)

	# The whole deck always fits — FitGrid sizes the cards to fill the body, no scrolling.
	_deck_grid = FitGrid.new()
	_deck_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_deck_grid.size_flags_vertical   = SIZE_EXPAND_FILL
	root.add_child(_deck_grid)

	_status_lbl = Label.new()
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.add_theme_font_size_override("font_size", 26 if _compact else 22)
	root.add_child(_status_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	root.add_child(btn_row)

	_upgrade_btn = Button.new()
	_upgrade_btn.add_theme_font_size_override("font_size", 30 if _compact else 26)
	_upgrade_btn.custom_minimum_size = Vector2(440, 120) if _compact else Vector2(380, 84)
	_upgrade_btn.pressed.connect(_apply_upgrade)
	btn_row.add_child(_upgrade_btn)


func _rebuild_deck() -> void:
	_entries.clear()
	_selected_idx = -1

	var cards: Array = []
	var deck: Array = GameData.current_run.deck.duplicate()
	for i in deck.size():
		var dc: DeckCard = deck[i]
		var data := CardData.get_card(dc.id)
		if data == null:
			continue
		var ui := CardUI.create(dc.make_instance())

		# Only fieldable deck units are valid targets — spells aren't placed as units, and
		# the King isn't drawn from the deck (so a deck-side change never reaches the board).
		var is_target := data.is_deck_unit()
		var eligible := is_target and not _done
		if not eligible:
			ui.modulate = Color(1, 1, 1, 0.35)
		else:
			var entry_idx := _entries.size()
			ui.pressed.connect(func(): _on_card_pressed(entry_idx))

		if is_target:
			_entries.append({ "card": dc, "deck_idx": i, "ui": ui })

		cards.append(ui)

	_deck_grid.set_cards(cards)
	_refresh()


func _on_card_pressed(entry_idx: int) -> void:
	if _done:
		return
	if _selected_idx == entry_idx:
		_entries[entry_idx].ui.set_selected(false)
		_selected_idx = -1
	else:
		if _selected_idx >= 0:
			_entries[_selected_idx].ui.set_selected(false)
		_selected_idx = entry_idx
		_entries[entry_idx].ui.set_selected(true)
	_refresh()


func _refresh() -> void:
	var gold: int = GameData.current_run.gold
	_gold_lbl.text = "Gold  %d" % gold
	_upgrade_btn.text = "Upgrade %s  (%d Gold)" % [DeckCard.attr_label(_attr), EVENT_COST]

	if _done:
		_upgrade_btn.disabled = true
		return
	if _selected_idx < 0:
		_status_lbl.text = "Select a unit to train"
		_status_lbl.modulate = Color(0.65, 0.65, 0.65)
		_upgrade_btn.disabled = true
		return

	var can_afford := gold >= EVENT_COST
	var card_name: String = CardData.get_card(_entries[_selected_idx].card.id).display_name
	if can_afford:
		_status_lbl.text = "Train %s  (+1 %s)" % [card_name, DeckCard.attr_label(_attr)]
		_status_lbl.modulate = Color(0.4, 1.0, 0.55)
	else:
		_status_lbl.text = "Not enough gold to train %s" % card_name
		_status_lbl.modulate = Color(1.0, 0.4, 0.4)
	_upgrade_btn.disabled = not can_afford


func _apply_upgrade() -> void:
	if _done or _selected_idx < 0 or GameData.current_run.gold < EVENT_COST:
		return
	var entry: Dictionary = _entries[_selected_idx]
	var card_name: String = CardData.get_card(entry.card.id).display_name
	GameData.current_run.gold -= EVENT_COST
	entry.card.bump(_attr, 1)
	GameData.save_run()
	_done = true
	_rebuild_deck()
	_status_lbl.text = "%s gained +1 %s." % [card_name, DeckCard.attr_label(_attr)]
	_status_lbl.modulate = Color(0.4, 1.0, 0.55)


func _leave() -> void:
	GameData.current_event_attr = ""
	get_tree().change_scene_to_file("res://scenes/map.tscn")
