extends Control

# Card catalogue / art-coverage audit: every card the composition system can produce — each
# multiset of up to 2 elements and up to 2 chess pieces (the combine caps, see CardData.can_combine)
# — shown with its illustration if one exists, or the placeholder if not. Cards whose composition
# is an AUTHORED card (e.g. earth+water → "Clay") resolve to that card's art/name. A header tells
# you the art coverage and lets you filter to just the cards with art, or just the ones still
# missing it. Reached from the hub (game_world). Read-only.
#
# NOTE: we resolve art from authored data + files on disk and never call CardData.get_card() on a
# derived composition — that would register the derived card into CardData._all and leak it into
# shop/reward pools for the rest of the session.

var _compact := false
var _tile_w := 70.0
var _with_art := true
var _missing_art := false

var _grid: HFlowContainer
var _summary: Label
var _tiles: Array = []   # [{ "ctrl": Control, "has_art": bool }]
var _placeholder: Texture2D


func _ready() -> void:
	if GameData.current_profile == null or GameData.current_slot < 0:
		Nav.goto.call_deferred("res://scenes/game_slots.tscn")
		return
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)
	_compact = UIScale.is_compact()
	_tile_w = 96.0 if _compact else 66.0
	_placeholder = load("res://assets/cards/placeholder.png")
	_build_ui()
	_build_catalogue()
	_apply_filter()


# ── Composition enumeration ──────────────────────────────────────────────────────────────

# Multisets (size 0,1,2 — unordered, with repetition) of the given items.
func _multisets(items: Array) -> Array:
	var out: Array = [[]]
	var n := items.size()
	for i in n:
		out.append([items[i]])
	for i in n:
		for j in range(i, n):
			out.append([items[i], items[j]])
	return out


# Every distinct composition key in the space (skipping the empty one), sorted.
func _all_keys() -> Array:
	var elem_sets := _multisets(Materials.ELEMENTS)
	var chess_sets := _multisets(Materials.PIECES)
	var seen: Dictionary = {}
	var keys: Array = []
	for e: Array in elem_sets:
		for c: Array in chess_sets:
			if e.is_empty() and c.is_empty():
				continue
			var key := CardData.composition_key(e, c)
			if not seen.has(key):
				seen[key] = true
				keys.append(key)
	keys.sort()
	return keys


# Maps each authored card's composition → that card, so named spells (Clay = earth+water) and
# every authored card resolve to their real id/art instead of a derived key.
func _authored_by_composition() -> Dictionary:
	var map: Dictionary = {}
	for card: CardData in CardData.all():
		var key := CardData.composition_key(card.elements, card.chess_pieces)
		if not key.is_empty():
			map[key] = card
	return map


# ── Build ────────────────────────────────────────────────────────────────────────────────

func get_chrome() -> Dictionary:
	return {"title": "Collection", "exit": _on_back, "show_footer": true}


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(root)

	# Screen-specific toolbar (the header stays pure catalog fields + title + ✕) — art-coverage
	# summary + filters, none of which are run-status data.
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 16)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", 26 if _compact else 16)
	_summary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_summary.modulate = Color(0.8, 0.82, 0.9)
	toolbar.add_child(_summary)

	toolbar.add_child(Control.new())
	toolbar.get_child(1).size_flags_horizontal = SIZE_EXPAND_FILL

	toolbar.add_child(_filter_toggle("With art", true, func(on: bool) -> void:
		_with_art = on
		_apply_filter()
	))
	toolbar.add_child(_filter_toggle("Missing art", true, func(on: bool) -> void:
		_missing_art = on
		_apply_filter()
	))
	root.add_child(toolbar)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	pad.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(pad)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pad.add_child(scroll)

	_grid = HFlowContainer.new()
	_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(_grid)


func _filter_toggle(text: String, on: bool, cb: Callable) -> CheckButton:
	var t := CheckButton.new()
	t.text = text
	t.button_pressed = on
	t.add_theme_font_size_override("font_size", 24 if _compact else 14)
	t.toggled.connect(cb)
	return t


func _build_catalogue() -> void:
	var authored := _authored_by_composition()
	var with_art := 0
	var keys := _all_keys()
	for key: String in keys:
		var card: CardData = authored.get(key, null)
		var art_id := card.id if card != null else key
		var label := card.display_name if card != null else key
		var path := "res://assets/cards/%s.png" % art_id
		var has_art := ResourceLoader.exists(path)
		if has_art:
			with_art += 1
		var tile := _tile(label, art_id, path, has_art)
		_grid.add_child(tile)
		_tiles.append({"ctrl": tile, "has_art": has_art})
	_summary.text = "Art: %d / %d   " % [with_art, keys.size()]


func _tile(label: String, art_id: String, path: String, has_art: bool) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	v.tooltip_text = "%s\n%s.png%s" % [label, art_id, "" if has_art else "  (missing)"]

	var tex := TextureRect.new()
	tex.texture = load(path) if has_art else _placeholder
	tex.custom_minimum_size = Vector2(_tile_w, _tile_w * DeckUI.CARD_RATIO)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if not has_art:
		tex.modulate = Color(0.5, 0.5, 0.55)
	v.add_child(tex)

	var id_lbl := Label.new()
	id_lbl.text = art_id
	id_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	id_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	id_lbl.custom_minimum_size.x = _tile_w
	id_lbl.add_theme_font_size_override("font_size", 15 if _compact else 10)
	id_lbl.add_theme_color_override("font_color", Color(0.7, 0.72, 0.8))
	v.add_child(id_lbl)

	var tag := Label.new()
	tag.text = "art" if has_art else "missing"
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.add_theme_font_size_override("font_size", 15 if _compact else 10)
	tag.add_theme_color_override("font_color",
		Color(0.6, 0.85, 0.6) if has_art else Color(0.88, 0.55, 0.5))
	v.add_child(tag)
	return v


func _apply_filter() -> void:
	for t: Dictionary in _tiles:
		var has_art: bool = t["has_art"]
		var ctrl: Control = t["ctrl"]
		ctrl.visible = (has_art and _with_art) or (not has_art and _missing_art)


func _on_back() -> void:
	Nav.goto("res://scenes/game_world.tscn")
