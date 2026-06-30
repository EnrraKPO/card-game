extends Control

# The deck builder (reached from the Decks screen's "Edit Deck →"). Edits an OwnedDeck by
# drawing cards from two sources, with PER-DECK non-competing accounting:
#   • innate King cards — free up to the King's template quantity (DeckData.innate_count);
#   • collection cards — up to the count the player owns (ProfileData.collection).
# So a card's cap = innate(King) + owned. Deck size is OwnedDeck.MIN_CARDS..MAX_CARDS (the
# King is the deck's anchor, shown but not counted). Removing the King drops every innate
# allotment to 0, so King-dependent cards go over-cap and grey out — and the deck can't be
# saved until the King is restored. Edits are on a working copy; Save commits, Back discards.

var _deck: OwnedDeck
var _cards: Array = []          # Array[DeckCard]: working copy
var _king_present := true
var _compact := false
var _tile_w := 84.0

var _king_holder: VBoxContainer
var _deck_flow: HFlowContainer
var _pool_flow: HFlowContainer
var _deck_header: Label
var _status: Label
var _save_btn: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	if GameData.current_profile == null or GameData.current_slot < 0:
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return
	_deck = _find_deck(GameData.editing_deck_id)
	if _deck == null:
		get_tree().change_scene_to_file.call_deferred("res://scenes/deck_screen.tscn")
		return
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)
	_compact = UIScale.is_compact()
	_tile_w = 130.0 if _compact else 112.0
	for dc: DeckCard in _deck.cards:
		_cards.append(dc.clone())
	_build_ui()
	_rebuild()


func _find_deck(deck_id: String) -> OwnedDeck:
	for od: OwnedDeck in GameData.current_profile.decks:
		if od.id == deck_id:
			return od
	return null


# ── layout ──────────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var s := ScreenUI.scaffold(self, "Edit Deck")
	_save_btn = Button.new()
	_save_btn.text = "Save"
	_save_btn.add_theme_font_size_override("font_size", 30 if _compact else 22)
	_save_btn.custom_minimum_size = Vector2(220, 96) if _compact else Vector2(160, 56)
	_save_btn.pressed.connect(_on_save)
	s.header.add_child(_save_btn)
	ScreenUI.attach_exits(_on_back, s.header, s.footer)

	var body: BoxContainer = VBoxContainer.new() if _compact else HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	s.root.add_child(body)
	body.add_child(_build_deck_pane())
	body.add_child(_build_pool_pane())

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 24 if _compact else 19)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var status_pad := MarginContainer.new()
	for side in ["top", "bottom"]:
		status_pad.add_theme_constant_override("margin_" + side, 8)
	status_pad.add_child(_status)
	s.root.add_child(status_pad)


func _build_deck_pane() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.size_flags_vertical = SIZE_EXPAND_FILL
	var box := _pane_box(panel)

	_deck_header = Label.new()
	_deck_header.add_theme_font_size_override("font_size", 28 if _compact else 20)
	box.add_child(_deck_header)

	_king_holder = VBoxContainer.new()
	_king_holder.add_theme_constant_override("separation", 4)
	box.add_child(_king_holder)

	box.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_deck_flow = HFlowContainer.new()
	_deck_flow.size_flags_horizontal = SIZE_EXPAND_FILL
	_deck_flow.add_theme_constant_override("h_separation", 8)
	_deck_flow.add_theme_constant_override("v_separation", 8)
	scroll.add_child(_deck_flow)
	return panel


func _build_pool_pane() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.size_flags_vertical = SIZE_EXPAND_FILL
	var box := _pane_box(panel)

	var title := Label.new()
	title.text = "Available  (tap to add)"
	title.add_theme_font_size_override("font_size", 28 if _compact else 20)
	box.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_pool_flow = HFlowContainer.new()
	_pool_flow.size_flags_horizontal = SIZE_EXPAND_FILL
	_pool_flow.add_theme_constant_override("h_separation", 8)
	_pool_flow.add_theme_constant_override("v_separation", 8)
	scroll.add_child(_pool_flow)
	return panel


func _pane_box(panel: PanelContainer) -> VBoxContainer:
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)
	return box


# ── deck rules ──────────────────────────────────────────────────────────────────────────

# Free innate allotment of a card for this deck's King (0 while the King is removed).
func _innate(card_id: String) -> int:
	return DeckData.innate_count(_deck.king_id, card_id) if _king_present else 0


# Max copies of a card this deck may hold: innate allotment + owned collection count.
func _cap(card_id: String) -> int:
	return _innate(card_id) + GameData.current_profile.collection.count(card_id)


func _count(card_id: String) -> int:
	var n := 0
	for dc: DeckCard in _cards:
		if dc.id == card_id:
			n += 1
	return n


# Distinct card ids currently in the working deck, sorted.
func _distinct_deck_ids() -> Array:
	var seen: Dictionary = {}
	for dc: DeckCard in _cards:
		seen[dc.id] = true
	var out: Array = seen.keys()
	out.sort()
	return out


# Every card the player could put in this deck: the King's template cards + collection.
func _pool_ids() -> Array:
	var seen: Dictionary = {}
	for id: String in DeckData.get_deck(_deck.king_id):
		seen[id] = true
	for id: String in GameData.current_profile.collection.ids():
		seen[id] = true
	var out: Array = seen.keys()
	out.sort()
	return out


func _deck_valid() -> bool:
	if not _king_present:
		return false
	if _cards.size() < OwnedDeck.MIN_CARDS or _cards.size() > OwnedDeck.MAX_CARDS:
		return false
	for id: String in _distinct_deck_ids():
		if _count(id) > _cap(id):
			return false
	return true


# ── actions ─────────────────────────────────────────────────────────────────────────────

func _add(card_id: String) -> void:
	if _cards.size() >= OwnedDeck.MAX_CARDS or _count(card_id) >= _cap(card_id):
		return
	_cards.append(DeckCard.make(card_id))
	_rebuild()


func _remove(card_id: String) -> void:
	for i in range(_cards.size() - 1, -1, -1):
		if _cards[i].id == card_id:
			_cards.remove_at(i)
			break
	_rebuild()


func _toggle_king() -> void:
	_king_present = not _king_present
	_rebuild()


func _on_save() -> void:
	if not _deck_valid():
		return
	_deck.cards = _cards
	GameData.save_profile()
	get_tree().change_scene_to_file("res://scenes/deck_screen.tscn")


func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/deck_screen.tscn")


# ── render ──────────────────────────────────────────────────────────────────────────────

func _rebuild() -> void:
	_deck_header.text = "Deck  %d / %d  (min %d)" % [_cards.size(), OwnedDeck.MAX_CARDS, OwnedDeck.MIN_CARDS]
	_rebuild_king()

	for child in _deck_flow.get_children():
		child.queue_free()
	for id: String in _distinct_deck_ids():
		var over := _count(id) > _cap(id)
		var color := Color(1.0, 0.5, 0.5) if over else Color(0.8, 0.82, 0.9)
		_deck_flow.add_child(_card_tile(id, "x%d" % _count(id), color, false, _remove.bind(id)))

	for child in _pool_flow.get_children():
		child.queue_free()
	var full := _cards.size() >= OwnedDeck.MAX_CARDS
	for id: String in _pool_ids():
		var cap := _cap(id)
		var have := _count(id)
		var maxed := have >= cap or full
		_pool_flow.add_child(_card_tile(id, "%d / %d" % [have, cap],
			Color(0.6, 0.62, 0.72), maxed, _add.bind(id)))

	_status.text = _status_text()
	_status.add_theme_color_override("font_color",
		Color(0.6, 0.85, 0.6) if _deck_valid() else Color(0.95, 0.7, 0.5))
	_save_btn.disabled = not _deck_valid()


func _rebuild_king() -> void:
	for child in _king_holder.get_children():
		child.queue_free()

	# King card on the left (kept at thumbnail size — a Control fills its container by
	# default, which would blow the card up), label + remove/restore button beside it.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_king_holder.add_child(row)

	var king := DeckUI.card_thumbnail(_deck.king_id, _tile_w, true)
	king.size_flags_horizontal = SIZE_SHRINK_CENTER
	king.size_flags_vertical = SIZE_SHRINK_CENTER
	if not _king_present:
		king.modulate = Color(1, 1, 1, 0.25)
	row.add_child(king)

	var side := VBoxContainer.new()
	side.size_flags_vertical = SIZE_SHRINK_CENTER
	side.add_theme_constant_override("separation", 6)
	row.add_child(side)

	var lbl := Label.new()
	lbl.text = "King"
	lbl.add_theme_font_size_override("font_size", 22 if _compact else 14)
	side.add_child(lbl)

	var btn := Button.new()
	btn.text = "Restore King" if not _king_present else "Remove King"
	btn.add_theme_font_size_override("font_size", 18 if _compact else 12)
	btn.pressed.connect(_toggle_king)
	side.add_child(btn)


func _status_text() -> String:
	if not _king_present:
		return "Restore the King to save — its innate cards are disabled without it."
	var n := _cards.size()
	if n < OwnedDeck.MIN_CARDS:
		return "Add %d more — decks need at least %d cards." % [OwnedDeck.MIN_CARDS - n, OwnedDeck.MIN_CARDS]
	if n > OwnedDeck.MAX_CARDS:
		return "Remove %d — decks hold at most %d cards." % [n - OwnedDeck.MAX_CARDS, OwnedDeck.MAX_CARDS]
	for id: String in _distinct_deck_ids():
		if _count(id) > _cap(id):
			var card := CardData.get_card(id)
			return "Too many %s (%d, own %d)." % [
				card.display_name if card != null else id, _count(id), _cap(id)]
	return "Deck ready — %d cards." % n


# A card thumbnail with a caption below; `on_click` fires on tap (CardUI.pressed).
func _card_tile(card_id: String, caption: String, caption_color: Color, dim: bool, on_click: Callable) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	var thumb := DeckUI.card_thumbnail(card_id, _tile_w, true)
	if dim:
		thumb.modulate = Color(1, 1, 1, 0.3)
	if thumb is CardUI and on_click.is_valid():
		(thumb as CardUI).pressed.connect(on_click)
	v.add_child(thumb)
	var cap := Label.new()
	cap.text = caption
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 18 if _compact else 12)
	cap.add_theme_color_override("font_color", caption_color)
	v.add_child(cap)
	return v
