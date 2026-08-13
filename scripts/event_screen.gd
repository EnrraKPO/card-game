extends Control

# A "?" site: pay gold to permanently raise one chosen deck card by +1 in the stat
# this node rolled (GameData.current_event_attr, set by NodeKindEvent). The trainer can be
# used repeatedly in a single visit, but each upgrade DOUBLES the price of the next one.
# Spells can't be placed as units, so only units are eligible.
const EVENT_COST := 40

var _attr: String = "attack"
var _entries: Array = []      # { "card": DeckCard, "deck_idx": int, "ui": CardUI }
var _selected_idx: int = -1
var _cost: int = EVENT_COST   # price of the NEXT upgrade; doubles after each purchase
var _compact := false

var _deck_grid: FitGrid
var _gold_lbl: Label
var _status_lbl: Label
var _upgrade_btn: Button


func _ready() -> void:
	Sfx.music("music_special_event")
	Sfx.play("map_event_open")
	_attr = GameData.current_event_attr
	if _attr.is_empty():
		_attr = DeckCard.UPGRADABLE[0]
	_build_ui()
	_rebuild_deck()


func get_chrome() -> Dictionary:
	return {"title": Loc.t("event.title"), "exit": _leave, "show_footer": true}


func _build_ui() -> void:
	_compact = UIScale.is_compact()
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 16)
	add_child(root)

	var title := Label.new()
	title.text = Loc.t("event.trainer_title")
	title.add_theme_font_size_override("font_size", 52 if _compact else 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)

	var blurb := Label.new()
	blurb.text = Loc.t("event.blurb", {"stat": DeckCard.attr_label(_attr)})
	blurb.add_theme_font_size_override("font_size", 26 if _compact else 22)
	blurb.add_theme_color_override("font_color", Color("6b5636"))
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(blurb)

	_gold_lbl = Label.new()
	_gold_lbl.add_theme_font_size_override("font_size", 28 if _compact else 24)
	_gold_lbl.add_theme_color_override("font_color", Color("9c7a10"))
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

	_upgrade_btn = ScreenUI.action_button("", _apply_upgrade,
		Vector2(440, 120) if _compact else Vector2(380, 84), 30 if _compact else 26,
		ScreenUI.CHROME_CONFIRM)
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
		var eligible := is_target
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
	# See the shop's twin: pressing the pick again clears, anything else is one assignment.
	if _selected_idx == entry_idx:
		_selected_idx = -1
		Selection.clear()
	else:
		_selected_idx = entry_idx
		Vfx.play("card_select_lift", _entries[entry_idx].ui)   # entry carries the select sound
		Selection.select(_entries[entry_idx].ui)
	_refresh()


func _refresh() -> void:
	var gold: int = GameData.current_run.gold
	_gold_lbl.text = Loc.t("event.gold", {"n": gold})
	_upgrade_btn.text = Loc.t("event.upgrade_btn", {"stat": DeckCard.attr_label(_attr), "n": _cost})

	if _selected_idx < 0:
		_status_lbl.text = Loc.t("event.select_prompt")
		_status_lbl.add_theme_color_override("font_color", Color("5a5248"))
		_upgrade_btn.disabled = true
		return

	var can_afford := gold >= _cost
	var card_name: String = CardData.get_card(_entries[_selected_idx].card.id).display_name
	if can_afford:
		_status_lbl.text = Loc.t("event.train", {"name": card_name, "stat": DeckCard.attr_label(_attr)})
		_status_lbl.add_theme_color_override("font_color", Color("1f7a35"))
	else:
		_status_lbl.text = Loc.t("event.not_enough", {"name": card_name})
		_status_lbl.add_theme_color_override("font_color", Color("8a2020"))
	_upgrade_btn.disabled = not can_afford


func _apply_upgrade() -> void:
	if _selected_idx < 0 or GameData.current_run.gold < _cost:
		return
	var entry: Dictionary = _entries[_selected_idx]
	var card_name: String = CardData.get_card(entry.card.id).display_name
	GameData.current_run.gold -= _cost
	# The training lands on the chosen card: the golden top-to-bottom shine (entry carries
	# the upgrade sound), plus the spent gold sliding off the counter.
	Vfx.play("card_upgrade_shine", entry.ui)
	Vfx.play("gold_spend_slide", _gold_lbl, {"text": "-%d" % _cost})
	# INERT (2026-08-13 ruling): the permanent deck-card bump rode the nuked write form. The
	# gold is spent and the shine plays; the stat does not move until the sanctioned form
	# exists. DeckCard.bump is the storage writer it went through.
	# Each training doubles the price of the next one within this visit.
	_cost *= 2
	GameData.save_run()
	_rebuild_deck()
	_status_lbl.text = Loc.t("event.gained", {"name": card_name, "stat": DeckCard.attr_label(_attr)})
	_status_lbl.add_theme_color_override("font_color", Color("1f7a35"))


func _leave() -> void:
	GameData.current_event_attr = ""
	Nav.goto("res://scenes/map.tscn")
