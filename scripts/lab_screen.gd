extends Control

# The Laboratory (hub's "Lab" button): a composed crafting ENVIRONMENT. The artifacts are
# authored nodes under $Stage (positioned freely in the editor — names must match the
# ARTIFACTS keys); the whole Stage uniform-scales to fit the screen (like the cards). The
# Back bar, the resource inventory (pinned at the bottom) and the feature panels are
# responsive code overlays on top. Click/tap an artifact to open its panel (collapsible via
# ✕; one open at a time); drag OR tap a resource token to fill the open panel's slots.
# Artifacts:
#   • Refinery — drop an essence, refine 10 of it into 1 matching stone.
#   • Card Forge — drop stones + chess pieces to mint a unit card into the collection.
#   • King Forge — drop a King Piece + 2 stones; the stones' elements pick the King.
# Items are fungible, so tokens just represent MaterialBag counts; slots stage an id and the
# artifact validates/spends on its action button. See Lab.

const DESIGN := Vector2(1280, 720)   # the Stage's authored canvas size (scaled to fit)

const ARTIFACTS := ["refinery", "card_forge", "king_forge"]
const NAMES := {"refinery": "Refinery", "card_forge": "Card Forge", "king_forge": "King Forge"}
const SUBTITLES := {
	"refinery":   "Drop an essence, then refine 10 of it into 1 matching stone.",
	"card_forge": "Drop stones + chess pieces to mint a unit card into your collection.",
	"king_forge": "Drop 1 King Piece + 2 stones — the two stones' elements choose the King.",
}

var _compact := false
var _inv_height := 160.0
var _open_key := ""

var _stage: Control
var _panel_host: Control
var _panel_center: MarginContainer
var _inventory: HFlowContainer

# Refinery widgets (valid only while it's the open artifact)
var _refinery_slot: DropSlot
var _refine_btn: Button
var _refine_status: Label

# King Forge widgets
var _king_slot: DropSlot
var _stone_slots: Array[DropSlot] = []
var _forge_preview: Control
var _forge_btn: Button
var _forge_status: Label

# Card Forge widgets
var _mint_stone_slots: Array[DropSlot] = []
var _mint_piece_slots: Array[DropSlot] = []
var _mint_preview: Control
var _mint_btn: Button
var _mint_status: Label


func _ready() -> void:
	if GameData.current_profile == null or GameData.current_slot < 0:
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)
	_compact = UIScale.is_compact()
	_inv_height = 220.0 if _compact else 150.0

	_stage = $Stage
	_wire_artifacts()
	_build_overlays()
	_rebuild_inventory()

	get_viewport().size_changed.connect(_fit_stage)
	_fit_stage()


# ── Stage (authored artifacts) ──────────────────────────────────────────────────────────

func _wire_artifacts() -> void:
	for key: String in ARTIFACTS:
		var node := _stage.get_node_or_null(NodePath(key)) as Control
		if node == null:
			continue
		node.tooltip_text = SUBTITLES.get(key, NAMES.get(key, key))
		node.mouse_entered.connect(func() -> void: node.modulate = Color(1.2, 1.2, 1.2))
		node.mouse_exited.connect(func() -> void: node.modulate = Color.WHITE)
		if node is BaseButton:
			(node as BaseButton).pressed.connect(_open.bind(key))


# Uniform-scale the Stage to fit the area above the inventory bar, centred.
func _fit_stage() -> void:
	if _stage == null:
		return
	var vp := get_viewport_rect().size
	var avail := Vector2(vp.x, maxf(vp.y - _inv_height, 1.0))
	var sc := minf(avail.x / DESIGN.x, avail.y / DESIGN.y)
	_stage.scale = Vector2(sc, sc)
	_stage.position = Vector2((vp.x - DESIGN.x * sc) * 0.5, (avail.y - DESIGN.y * sc) * 0.5)


# ── Overlays (Back bar, inventory, panel host) ──────────────────────────────────────────

func _build_overlays() -> void:
	var exit := func() -> void: get_tree().change_scene_to_file("res://scenes/game_world.tscn")

	# Title bar with the standard top-right ✕.
	var top := HBoxContainer.new()
	top.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
	top.offset_left = 12
	top.offset_top = 10
	top.offset_right = -12
	add_child(top)
	var title := Label.new()
	title.text = "   Laboratory"
	title.add_theme_font_size_override("font_size", 30 if _compact else 22)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(title)
	top.add_child(ScreenUI.close_button(exit))

	# Standard bottom-left Back, lifted above the pinned inventory bar so it never overlaps it.
	var back := ScreenUI.back_button(exit)
	back.anchor_left = 0.0; back.anchor_right = 0.0
	back.anchor_top = 1.0; back.anchor_bottom = 1.0
	back.offset_left = 16
	back.offset_right = 16 + back.custom_minimum_size.x
	back.offset_bottom = -(_inv_height + 16)
	back.offset_top = back.offset_bottom - back.custom_minimum_size.y
	add_child(back)

	# OS go-back / Esc: collapse an open artifact panel first, otherwise leave the Lab.
	Nav.set_back(func() -> void:
		if _open_key != "":
			_collapse()
		else:
			exit.call())

	# Panel host: covers the area above the inventory; hidden until an artifact opens.
	_panel_host = Control.new()
	_panel_host.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_panel_host.offset_bottom = -_inv_height
	_panel_host.visible = false
	add_child(_panel_host)
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.6)
	_panel_host.add_child(dim)
	_panel_center = MarginContainer.new()
	_panel_center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var m := 14 if _compact else 70
	for side in ["left", "right", "top", "bottom"]:
		_panel_center.add_theme_constant_override("margin_" + side, m)
	_panel_host.add_child(_panel_center)

	# Inventory bar (pinned bottom, always visible for dragging/tapping).
	add_child(_build_inventory_bar())


# ── Open / collapse ─────────────────────────────────────────────────────────────────────

func _open(key: String) -> void:
	_open_key = key
	for child in _panel_center.get_children():
		child.queue_free()
	_panel_center.add_child(_build_feature_panel(key))
	_panel_host.visible = true
	_refresh_open()


func _collapse() -> void:
	_open_key = ""
	for child in _panel_center.get_children():
		child.queue_free()
	_panel_host.visible = false
	_clear_feature_refs()


func _clear_feature_refs() -> void:
	_refinery_slot = null
	_refine_btn = null
	_refine_status = null
	_king_slot = null
	_stone_slots.clear()
	_forge_preview = null
	_forge_btn = null
	_forge_status = null
	_mint_stone_slots.clear()
	_mint_piece_slots.clear()
	_mint_preview = null
	_mint_btn = null
	_mint_status = null


func _build_feature_panel(key: String) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = SIZE_EXPAND_FILL
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 16)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = NAMES.get(key, key)
	title.add_theme_font_size_override("font_size", 32 if _compact else 24)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.add_theme_font_size_override("font_size", 30 if _compact else 20)
	close.custom_minimum_size = Vector2(72, 72) if _compact else Vector2(40, 36)
	close.pressed.connect(_collapse)
	header.add_child(close)

	var sub := Label.new()
	sub.text = SUBTITLES.get(key, "")
	sub.add_theme_font_size_override("font_size", 20 if _compact else 14)
	sub.modulate = Color(0.7, 0.72, 0.8)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(sub)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	match key:
		"refinery":   _refinery_body(body)
		"card_forge": _card_forge_body(body)
		"king_forge": _king_forge_body(body)
	return panel


# After a craft: refresh inventory counts and reset the open artifact's slots/preview.
func _refresh_open() -> void:
	match _open_key:
		"refinery":
			if is_instance_valid(_refinery_slot):
				_refinery_slot.clear()
			_update_refinery()
		"card_forge":
			for slot in _mint_stone_slots:
				slot.clear()
			for slot in _mint_piece_slots:
				slot.clear()
			_update_card_forge()
		"king_forge":
			if is_instance_valid(_king_slot):
				_king_slot.clear()
			for slot in _stone_slots:
				slot.clear()
			_update_forge()


# ── Inventory ───────────────────────────────────────────────────────────────────────────

func _build_inventory_bar() -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
	panel.offset_top = -_inv_height
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	var title := Label.new()
	title.text = "Resources  ·  drag or tap onto an open artifact's slots"
	title.add_theme_font_size_override("font_size", 22 if _compact else 15)
	title.modulate = Color(0.7, 0.72, 0.8)
	box.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(scroll)
	_inventory = HFlowContainer.new()
	_inventory.size_flags_horizontal = SIZE_EXPAND_FILL
	_inventory.add_theme_constant_override("h_separation", 10)
	_inventory.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_inventory)
	return panel


# Owned material ids, ordered pieces → essences → stones, skipping empties.
func _owned_material_ids() -> Array:
	var bag := GameData.current_profile.materials
	var ids: Array = []
	for piece: String in Materials.PIECES:
		if bag.count(Materials.piece_id(piece)) > 0:
			ids.append(Materials.piece_id(piece))
	for el: String in Materials.ELEMENTS:
		if bag.count(el) > 0:
			ids.append(el)
	for el: String in Materials.ELEMENTS:
		if bag.count(Materials.stone_id(el)) > 0:
			ids.append(Materials.stone_id(el))
	return ids


func _rebuild_inventory() -> void:
	for child in _inventory.get_children():
		child.queue_free()
	var bag := GameData.current_profile.materials
	var ids := _owned_material_ids()
	if ids.is_empty():
		var hint := Label.new()
		hint.text = "No resources yet — earn essence from encounters, then refine it here."
		hint.add_theme_font_size_override("font_size", 20 if _compact else 14)
		hint.modulate = Color(0.7, 0.72, 0.8)
		_inventory.add_child(hint)
		return
	for id: String in ids:
		var token := ResourceToken.new().setup(id, bag.count(id), _compact)
		token.clicked.connect(_on_token_clicked)
		_inventory.add_child(token)


# Tap-to-assign: route a clicked resource into the open artifact's first compatible slot
# (empty slots first, otherwise replace the first that accepts it). No-op when nothing's open.
func _on_token_clicked(id: String) -> void:
	if _open_key.is_empty():
		return
	var slots := _open_slots()
	for slot: DropSlot in slots:
		if slot.staged_id.is_empty() and slot.can_accept.call(id):
			slot.stage(id)
			return
	for slot: DropSlot in slots:
		if slot.can_accept.call(id):
			slot.stage(id)
			return


func _open_slots() -> Array:
	match _open_key:
		"refinery":
			return [_refinery_slot] if is_instance_valid(_refinery_slot) else []
		"card_forge":
			var cf: Array = []
			cf.append_array(_mint_stone_slots)
			cf.append_array(_mint_piece_slots)
			return cf
		"king_forge":
			var kf: Array = [_king_slot]
			kf.append_array(_stone_slots)
			return kf
	return []


# ── Refinery ────────────────────────────────────────────────────────────────────────────

func _refinery_body(box: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	_refinery_slot = DropSlot.new().setup("Essence", _compact)
	_refinery_slot.can_accept = func(id: String) -> bool: return id in Materials.ELEMENTS
	_refinery_slot.on_changed = _update_refinery
	row.add_child(_refinery_slot)

	_refine_btn = Button.new()
	_refine_btn.text = "Refine"
	_refine_btn.add_theme_font_size_override("font_size", 24 if _compact else 16)
	_refine_btn.custom_minimum_size = Vector2(0, 84) if _compact else Vector2(140, 0)
	_refine_btn.pressed.connect(_on_refine)
	row.add_child(_refine_btn)

	_refine_status = Label.new()
	_refine_status.add_theme_font_size_override("font_size", 19 if _compact else 13)
	_refine_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_refine_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_refine_status)


func _update_refinery() -> void:
	var el := _refinery_slot.staged_id
	if el.is_empty():
		_refine_status.text = "Drop an essence to refine."
		_refine_btn.disabled = true
		return
	var have := GameData.current_profile.materials.count(el)
	if have >= Lab.REFINE_RATIO:
		_refine_status.text = "Refine %d %s → 1 %s." % [
			Lab.REFINE_RATIO, Materials.short_name(el),
			Materials.display_name(Materials.stone_id(el))]
		_refine_btn.disabled = false
	else:
		_refine_status.text = "Need %d %s (have %d)." % [
			Lab.REFINE_RATIO, Materials.display_name(el), have]
		_refine_btn.disabled = true


func _on_refine() -> void:
	if Lab.refine(GameData.current_profile, _refinery_slot.staged_id):
		GameData.save_profile()
		_rebuild_inventory()
	_refresh_open()


# ── Card Forge ──────────────────────────────────────────────────────────────────────────

func _card_forge_body(box: VBoxContainer) -> void:
	var slots := HBoxContainer.new()
	slots.add_theme_constant_override("separation", 10)
	slots.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(slots)

	_mint_stone_slots.clear()
	for i in 2:
		var slot := DropSlot.new().setup("Stone", _compact)
		slot.can_accept = func(id: String) -> bool: return Materials.is_stone(id)
		slot.on_changed = _update_card_forge
		slots.add_child(slot)
		_mint_stone_slots.append(slot)
	_mint_piece_slots.clear()
	for i in 2:
		var slot := DropSlot.new().setup("Piece", _compact)
		slot.can_accept = func(id: String) -> bool: return Materials.is_piece(id) and Materials.piece_of(id) != "king"
		slot.on_changed = _update_card_forge
		slots.add_child(slot)
		_mint_piece_slots.append(slot)

	_mint_preview = CenterContainer.new()
	_mint_preview.custom_minimum_size.y = (150.0 if _compact else 104.0) * DeckUI.CARD_RATIO
	box.add_child(_mint_preview)

	_mint_status = Label.new()
	_mint_status.add_theme_font_size_override("font_size", 19 if _compact else 13)
	_mint_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mint_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_mint_status)

	_mint_btn = Button.new()
	_mint_btn.text = "Craft Card"
	_mint_btn.add_theme_font_size_override("font_size", 24 if _compact else 16)
	_mint_btn.custom_minimum_size = Vector2(0, 84) if _compact else Vector2(160, 0)
	_mint_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	_mint_btn.pressed.connect(_on_mint)
	box.add_child(_mint_btn)


func _staged_card_id() -> String:
	var elems: Array = []
	for slot in _mint_stone_slots:
		if not slot.staged_id.is_empty():
			elems.append(Materials.element_of(slot.staged_id))
	var pieces: Array = []
	for slot in _mint_piece_slots:
		if not slot.staged_id.is_empty():
			pieces.append(Materials.piece_of(slot.staged_id))
	if elems.is_empty() and pieces.is_empty():
		return ""
	# Resolve via the card's canonical id (authored cards now use their composition key as
	# id, so this is normally an identity — but it stays correct if an alias is ever added).
	var key := CardData.composition_key(elems, pieces)
	var card := CardData.get_card(key)
	return card.id if card != null else key


func _update_card_forge() -> void:
	for child in _mint_preview.get_children():
		child.queue_free()

	var card_id := _staged_card_id()
	if card_id.is_empty():
		_mint_status.text = "Drop ingredients to design a card."
		_mint_btn.disabled = true
		return

	var card := CardData.get_card(card_id)
	var card_name: String = card.display_name if card != null else card_id
	_mint_preview.add_child(DeckUI.card_thumbnail(card_id, 150.0 if _compact else 104.0, true))

	if not Lab.is_mintable(card_id):
		_mint_status.text = "Can't craft %s here." % card_name
		_mint_btn.disabled = true
	elif not Lab.can_mint(GameData.current_profile, card_id):
		_mint_status.text = "Costs %s." % Materials.summary(Lab.card_cost(card_id))
		_mint_btn.disabled = true
	else:
		_mint_status.text = "Craft %s  (own %d)" % [card_name, GameData.current_profile.collection.count(card_id)]
		_mint_btn.disabled = false


func _on_mint() -> void:
	var card_id := _staged_card_id()
	var card := CardData.get_card(card_id)
	var card_name: String = card.display_name if card != null else card_id
	if Lab.mint(GameData.current_profile, card_id):
		GameData.save_profile()
		_rebuild_inventory()
		_refresh_open()
		_mint_status.text = "Crafted %s!  (own %d)" % [card_name, GameData.current_profile.collection.count(card_id)]


# ── King Forge ──────────────────────────────────────────────────────────────────────────

func _king_forge_body(box: VBoxContainer) -> void:
	var slots := HBoxContainer.new()
	slots.add_theme_constant_override("separation", 12)
	slots.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(slots)

	_king_slot = DropSlot.new().setup("King Piece", _compact)
	_king_slot.can_accept = func(id: String) -> bool: return id == Lab.KING_PIECE
	_king_slot.on_changed = _update_forge
	slots.add_child(_king_slot)

	_stone_slots.clear()
	for i in 2:
		var slot := DropSlot.new().setup("Stone", _compact)
		slot.can_accept = func(id: String) -> bool: return Materials.is_stone(id)
		slot.on_changed = _update_forge
		slots.add_child(slot)
		_stone_slots.append(slot)

	_forge_preview = CenterContainer.new()
	_forge_preview.custom_minimum_size.y = (160.0 if _compact else 110.0) * DeckUI.CARD_RATIO
	box.add_child(_forge_preview)

	_forge_status = Label.new()
	_forge_status.add_theme_font_size_override("font_size", 19 if _compact else 13)
	_forge_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_forge_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_forge_status)

	_forge_btn = Button.new()
	_forge_btn.text = "Forge King"
	_forge_btn.add_theme_font_size_override("font_size", 24 if _compact else 16)
	_forge_btn.custom_minimum_size = Vector2(0, 84) if _compact else Vector2(160, 0)
	_forge_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	_forge_btn.pressed.connect(_on_forge)
	box.add_child(_forge_btn)


func _staged_element(slot: DropSlot) -> String:
	return Materials.element_of(slot.staged_id) if not slot.staged_id.is_empty() else ""


func _update_forge() -> void:
	for child in _forge_preview.get_children():
		child.queue_free()

	var a := _staged_element(_stone_slots[0])
	var b := _staged_element(_stone_slots[1])
	if a.is_empty() or b.is_empty():
		_forge_status.text = "Drop two stones to choose a King."
		_forge_btn.disabled = true
		return

	var king_id := Lab.king_id_for(a, b)
	var king := CardData.get_card(king_id)
	var king_name: String = king.display_name if king != null else king_id
	_forge_preview.add_child(DeckUI.king_thumbnail(king_id, 160.0 if _compact else 110.0))

	var profile := GameData.current_profile
	if king_id in profile.unlocked_kings:
		_forge_status.text = "%s already forged." % king_name
		_forge_btn.disabled = true
	elif _king_slot.staged_id.is_empty():
		_forge_status.text = "Add a King Piece to forge the %s." % king_name
		_forge_btn.disabled = true
	elif not Lab.can_forge(profile, a, b):
		_forge_status.text = "Not enough stones for the %s." % king_name
		_forge_btn.disabled = true
	else:
		_forge_status.text = "Forge the %s!" % king_name
		_forge_btn.disabled = false


func _on_forge() -> void:
	var a := _staged_element(_stone_slots[0])
	var b := _staged_element(_stone_slots[1])
	var king_id := Lab.forge(GameData.current_profile, a, b)
	if not king_id.is_empty():
		GameData.save_profile()
		_rebuild_inventory()
		_refresh_open()
		_show_king_celebration(king_id)
	else:
		_refresh_open()


# ── King-unlocked celebration ─────────────────────────────────────────────────────────

func _show_king_celebration(king_id: String) -> void:
	var king := CardData.get_card(king_id)
	var king_name: String = king.display_name if king != null else king_id
	var deck := _newest_deck_for(king_id)
	var vp := get_viewport_rect().size

	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	overlay.mouse_filter = MOUSE_FILTER_STOP
	add_child(overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.8)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	overlay.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 28 if _compact else 24)
	panel.add_child(pad)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	pad.add_child(box)

	var heading := Label.new()
	heading.text = "New King Forged!"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 42 if _compact else 32)
	heading.add_theme_color_override("font_color", Materials.color(Materials.piece_id("king")))
	box.add_child(heading)

	var thumb := DeckUI.king_thumbnail(king_id, 200.0 if _compact else 150.0, true)
	thumb.size_flags_horizontal = SIZE_SHRINK_CENTER
	box.add_child(thumb)

	var sub := Label.new()
	sub.text = "%s — its deck is unlocked!" % king_name
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 26 if _compact else 19)
	box.add_child(sub)

	if deck != null:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size = Vector2(0, minf(vp.y * 0.42, 360.0))
		var grid := DeckUI.deck_grid(deck, 4 if _compact else 6, 92.0 if _compact else 74.0)
		grid.size_flags_horizontal = SIZE_SHRINK_CENTER
		scroll.add_child(grid)
		box.add_child(scroll)

	var btn := Button.new()
	btn.text = "Continue"
	btn.add_theme_font_size_override("font_size", 26 if _compact else 18)
	btn.custom_minimum_size = Vector2(0, 84) if _compact else Vector2(200, 44)
	btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	btn.pressed.connect(func(): overlay.queue_free())
	box.add_child(btn)


func _newest_deck_for(king_id: String) -> OwnedDeck:
	var result: OwnedDeck = null
	for od: OwnedDeck in GameData.current_profile.decks:
		if od.king_id == king_id:
			result = od
	return result
