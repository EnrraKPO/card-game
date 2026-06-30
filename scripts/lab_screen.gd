extends Control

# The Laboratory (hub's "Lab" button): a crafting room laid out as a responsive page over a
# darkened illustration of the room. Header (title · EXP · ✕) on top, Back at the bottom; between
# them a WORKING AREA and the RESOURCES inventory sit SIDE BY SIDE on desktop (each uses the full
# height, so a short window never makes them overlap) and STACK on compact/mobile (where height is
# plentiful). The working area has two states that each fill it completely (so neither is cramped,
# and there's no dim modal): the "room", showing the three artifacts as BIG clickable objects; and,
# once one is clicked, that artifact's crafting workspace (slots + big preview + action) with a
# "‹ Lab" button back to the room. Drag OR tap a resource token to fill the open artifact's slots.
# The artifact art is read once from the authored $Stage nodes (named after the ARTIFACTS keys) and
# the $Stage is then discarded.
# Artifacts:
#   • Refinery — drop an essence, refine 10 of it into 1 matching stone.
#   • Card Forge — drop stones + chess pieces to mint a unit card into the collection.
#   • King Forge — drop a King Piece + 2 stones; the stones' elements pick the King.
# Items are fungible, so tokens just represent MaterialBag counts; slots stage an id and the
# artifact validates/spends on its action button. See Lab.

const ARTIFACTS := ["refinery", "card_forge", "king_forge"]
const NAMES := {"refinery": "Refinery", "card_forge": "Card Forge", "king_forge": "King Forge"}
const SUBTITLES := {
	"refinery":   "Drop an essence, then refine 10 of it into 1 matching stone.",
	"card_forge": "Drop stones + chess pieces to mint a unit card into your collection.",
	"king_forge": "Drop 1 King Piece + 2 stones — the two stones' elements choose the King.",
}

var _compact := false
var _open_key := ""

var _work_area: Control          # holds either the artifact "room" or an open crafting panel
var _artifact_view: Control      # the big clickable artifact objects (the room)
var _craft_panel: Control = null # the open artifact's crafting workspace (null in the room)
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

	_add_background()
	_build_layout()       # opens in the "room" view — the big artifact objects
	_rebuild_inventory()  # populate the resource tray (room view shows the full inventory)


# ── Background ──────────────────────────────────────────────────────────────────────────

# The illustrated room kept as a darkened, subtle backdrop (above the solid Background ColorRect,
# behind the UI) so the Lab still reads as a place without the busy art fighting the components.
func _add_background() -> void:
	var tex := load("res://assets/ui/lab/lab_background.png") as Texture2D
	if tex != null:
		var bg := TextureRect.new()
		bg.texture = tex
		bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.modulate = Color(0.42, 0.42, 0.48)   # dim the room so the UI sits clearly on top
		bg.mouse_filter = MOUSE_FILTER_IGNORE
		add_child(bg)
		move_child(bg, 1)   # index 0 is the Background ColorRect; keep this behind the room

	# A readability scrim over the dimmed room so panel text/edges stay crisp.
	var scrim := ColorRect.new()
	scrim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	scrim.color = Color(0.05, 0.05, 0.09, 0.45)
	scrim.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(scrim)


# ── Layout: header · working area (room ⇄ crafting) · inventory · back ───────────────────

func _build_layout() -> void:
	var exit := func() -> void: get_tree().change_scene_to_file("res://scenes/game_world.tscn")
	var inset := UIScale.safe_inset()

	var outer := MarginContainer.new()
	outer.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var margin := int(inset + 36.0)
	for side in ["left", "right", "top", "bottom"]:
		outer.add_theme_constant_override("margin_" + side, margin)
	add_child(outer)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 20)
	outer.add_child(col)

	# Header: title · EXP · ✕
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	col.add_child(header)
	var title := Label.new()
	title.text = "Laboratory"
	title.add_theme_font_size_override("font_size", 38 if _compact else 30)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
	if GameData.current_profile != null:
		header.add_child(ScreenUI.experience_bar_compact(GameData.current_profile, _compact))
	header.add_child(ScreenUI.close_button(exit))

	# Working area: the big artifact objects (the "room"), or an open artifact's crafting panel —
	# whichever is active fills it (clip as a safety so nothing ever bleeds outside).
	_work_area = Control.new()
	_work_area.size_flags_horizontal = SIZE_EXPAND_FILL
	_work_area.size_flags_vertical = SIZE_EXPAND_FILL
	_work_area.clip_contents = true
	_artifact_view = _build_artifact_view()
	_artifact_view.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_work_area.add_child(_artifact_view)

	# Working area + resources sit SIDE BY SIDE on desktop (each uses the full height, so a short
	# window never makes them overlap) and STACK on compact/mobile (where height is plentiful).
	var inv := _build_inventory_panel()
	if _compact:
		var area := VBoxContainer.new()
		area.size_flags_vertical = SIZE_EXPAND_FILL
		area.add_theme_constant_override("separation", 20)
		area.add_child(_work_area)
		area.add_child(inv)
		col.add_child(area)
	else:
		var area := HBoxContainer.new()
		area.size_flags_vertical = SIZE_EXPAND_FILL
		area.add_theme_constant_override("separation", 24)
		_work_area.size_flags_stretch_ratio = 2.6
		area.add_child(_work_area)
		inv.size_flags_horizontal = SIZE_EXPAND_FILL
		inv.size_flags_vertical = SIZE_EXPAND_FILL
		inv.size_flags_stretch_ratio = 1.0
		area.add_child(inv)
		col.add_child(area)

	# Footer: standard bottom-left Back.
	var footer := HBoxContainer.new()
	col.add_child(footer)
	footer.add_child(ScreenUI.back_button(exit))

	# OS go-back / Esc: from a crafting panel, return to the room first; otherwise leave the Lab.
	Nav.set_back(func() -> void:
		if _open_key != "":
			_close_artifact()
		else:
			exit.call())


# The "room": the kept artifact art shown as BIG clickable objects spread across the working area.
# Click one to open its crafting workspace. Art is read once from the authored $Stage nodes, which
# are then discarded.
func _build_artifact_view() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24 if _compact else 48)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var stage := get_node_or_null("Stage")
	for key: String in ARTIFACTS:
		var tex: Texture2D = null
		if stage != null:
			var n := stage.get_node_or_null(NodePath(key))
			if n is TextureButton:
				tex = (n as TextureButton).texture_normal
		row.add_child(_make_artifact_object(key, tex))
	if stage != null:
		stage.queue_free()
	return row


# One big artifact object: its art filling its share of the row, over a large name plate. Hovering
# lifts it slightly so it reads as a clickable object, not a tab.
func _make_artifact_object(key: String, tex: Texture2D) -> Control:
	var cell := VBoxContainer.new()
	cell.size_flags_horizontal = SIZE_EXPAND_FILL
	cell.size_flags_vertical = SIZE_EXPAND_FILL
	cell.add_theme_constant_override("separation", 8)

	var btn := TextureButton.new()
	btn.texture_normal = tex
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.size_flags_horizontal = SIZE_EXPAND_FILL
	btn.size_flags_vertical = SIZE_EXPAND_FILL
	btn.tooltip_text = SUBTITLES.get(key, NAMES.get(key, key))
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(_open.bind(key))
	btn.mouse_entered.connect(func() -> void: btn.modulate = Color(1.18, 1.18, 1.18))
	btn.mouse_exited.connect(func() -> void: btn.modulate = Color.WHITE)
	cell.add_child(btn)

	var name_lbl := Label.new()
	name_lbl.text = NAMES.get(key, key)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 36 if _compact else 30)
	name_lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.05, 0.9))
	name_lbl.add_theme_constant_override("outline_size", 6)
	name_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	cell.add_child(name_lbl)
	return cell


# ── Open / close an artifact's crafting workspace ───────────────────────────────────────

# Clicking an artifact swaps the room out for that artifact's crafting panel, which fills the whole
# working area (not a dim modal, not a cramped slice) — a "‹ Lab" button returns to the room.
func _open(key: String) -> void:
	_open_key = key
	_clear_feature_refs()
	if is_instance_valid(_craft_panel):
		_craft_panel.queue_free()
	_artifact_view.visible = false
	_craft_panel = _build_craft_panel(key)
	_craft_panel.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_work_area.add_child(_craft_panel)
	_refresh_open()
	_rebuild_inventory()


func _close_artifact() -> void:
	_open_key = ""
	if is_instance_valid(_craft_panel):
		_craft_panel.queue_free()
	_craft_panel = null
	_clear_feature_refs()
	_artifact_view.visible = true
	_rebuild_inventory()


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


# The selected artifact's crafting workspace, built to FILL the working area: a header (‹ Lab +
# name), the subtitle, then the crafting body (slots + big preview + action) claiming the slack.
func _build_craft_panel(key: String) -> Control:
	var panel := PanelContainer.new()
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 22 if _compact else 32)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	pad.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	box.add_child(header)
	var back := Button.new()
	back.text = "‹ Lab"
	back.add_theme_font_size_override("font_size", 28 if _compact else 22)
	back.custom_minimum_size = Vector2(200, 96) if _compact else Vector2(150, 60)
	back.pressed.connect(_close_artifact)
	header.add_child(back)
	var title := Label.new()
	title.text = NAMES.get(key, key)
	title.add_theme_font_size_override("font_size", 42 if _compact else 34)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)

	var sub := Label.new()
	sub.text = SUBTITLES.get(key, "")
	sub.add_theme_font_size_override("font_size", 24 if _compact else 19)
	sub.modulate = Color(0.72, 0.74, 0.82)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size.x = 300.0   # keep autowrap from inflating min height
	box.add_child(sub)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.alignment = BoxContainer.ALIGNMENT_CENTER   # centre when no child expands (e.g. Refinery)
	body.add_theme_constant_override("separation", 24 if _compact else 18)
	box.add_child(body)

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

# A big chunky resources panel: heading + a row of large tokens (drag or tap onto the open
# artifact's slots). Sits in the page's VBox flow with a generous fixed height.
func _build_inventory_panel() -> Control:
	var panel := PanelContainer.new()
	# Compact: a bottom bar (fixed tall). Desktop: a side column (min width; fills the body height).
	if _compact:
		panel.custom_minimum_size.y = 300.0
	else:
		panel.custom_minimum_size.x = 320.0
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	pad.add_child(box)

	var title := Label.new()
	title.text = "Resources" if not _compact else "Resources  ·  drag or tap onto the artifact's slots"
	title.add_theme_font_size_override("font_size", 26 if _compact else 22)
	title.modulate = Color(0.78, 0.8, 0.9)
	box.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(scroll)
	_inventory = HFlowContainer.new()
	_inventory.size_flags_horizontal = SIZE_EXPAND_FILL
	_inventory.add_theme_constant_override("h_separation", 14)
	_inventory.add_theme_constant_override("v_separation", 14)
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
	# Show the full inventory always (the panel is a persistent workspace); tokens the current
	# artifact can't use are dimmed so the relevant ones still stand out.
	var ids := _owned_material_ids()
	if ids.is_empty():
		var hint := Label.new()
		hint.text = "No resources yet — earn essence from encounters, then refine it here."
		hint.add_theme_font_size_override("font_size", 24 if _compact else 18)
		hint.modulate = Color(0.7, 0.72, 0.8)
		_inventory.add_child(hint)
		return
	for id: String in ids:
		var token := ResourceToken.new().setup(id, bag.count(id), _compact)
		token.clicked.connect(_on_token_clicked)
		# Inside an artifact, dim what it can't use; in the room, show everything at full strength.
		if _open_key != "" and not _relevant_to_open(id):
			token.modulate = Color(1, 1, 1, 0.4)
		_inventory.add_child(token)


# Tap-to-assign: route a clicked resource into the open artifact's first empty compatible slot.
# If the artifact can't use it at all, say so; if its slots are full, ask the player to clear one.
func _on_token_clicked(id: String) -> void:
	if _open_key.is_empty():
		return
	if not _relevant_to_open(id):
		_set_open_status("The %s can't use that." % NAMES.get(_open_key, _open_key))
		return
	for slot: DropSlot in _open_slots():
		if slot.staged_id.is_empty() and slot.can_accept.call(id):
			slot.stage(id)
			return
	_set_open_status("No empty slots available — tap a filled slot to clear it.")


# Set the open artifact's status line (each facility has its own). Lasts until the next slot
# change refreshes it via the facility's _update_*.
func _set_open_status(text: String) -> void:
	var label: Label = null
	match _open_key:
		"refinery":   label = _refine_status
		"card_forge": label = _mint_status
		"king_forge": label = _forge_status
	if is_instance_valid(label):
		label.text = text


# True if the open facility can use this resource — i.e. any of its slots accepts it.
# Reuses the slots' own can_accept rules so the inventory filter never drifts from them.
func _relevant_to_open(id: String) -> bool:
	for slot: DropSlot in _open_slots():
		if slot.can_accept.call(id):
			return true
	return false


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
	var cols := _columns(box)
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	var slots := _slot_grid(1)
	left.add_child(slots)

	_refinery_slot = DropSlot.new().setup("Essence", _compact)
	_refinery_slot.can_accept = func(id: String) -> bool: return id in Materials.ELEMENTS
	_refinery_slot.on_changed = _update_refinery
	slots.add_child(_refinery_slot)

	_refine_status = Label.new()
	_refine_status.add_theme_font_size_override("font_size", 22 if _compact else 15)
	_refine_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_refine_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_refine_status.custom_minimum_size.x = 240.0   # keep autowrap from inflating min height (see sub)
	right.add_child(_refine_status)

	_refine_btn = Button.new()
	_refine_btn.text = "Refine"
	_refine_btn.add_theme_font_size_override("font_size", 32 if _compact else 26)
	_refine_btn.custom_minimum_size = Vector2(0, 116) if _compact else Vector2(0, 80)
	_refine_btn.size_flags_horizontal = SIZE_FILL
	_refine_btn.pressed.connect(_on_refine)
	right.add_child(_refine_btn)


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


# ── Panel layout scaffolding (two-column on desktop, stacked on compact) ─────────────────

# Splits a feature-panel body into [left, right] columns: side-by-side (slots | preview+action)
# on a wide desktop panel so it fills the width, or — on compact — a single stacked column
# (both entries are the body itself, so callers just append slots → preview → button in order).
func _columns(body: VBoxContainer) -> Array:
	if _compact:
		return [body, body]
	var row := HBoxContainer.new()
	row.size_flags_vertical = SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 32)
	body.add_child(row)
	var cols: Array = []
	for i in 2:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = SIZE_EXPAND_FILL
		col.size_flags_vertical = SIZE_EXPAND_FILL
		col.alignment = BoxContainer.ALIGNMENT_CENTER   # centre content when nothing expands
		col.add_theme_constant_override("separation", 16)
		row.add_child(col)
		cols.append(col)
	return cols


# A centred holder for an artifact's drop slots, in a fixed `columns`-wide grid. A GridContainer
# (not an HFlowContainer) on purpose: FlowContainer's minimum size is width-dependent and
# order-sensitive, so a panel rebuilt while hidden then shown could carry a stale single-row
# minimum and blow the column width on the next open. The grid's minimum is deterministic.
func _slot_grid(columns: int) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.size_flags_horizontal = SIZE_SHRINK_CENTER
	grid.size_flags_vertical = SIZE_SHRINK_CENTER
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	return grid


# An expanding preview holder. Deliberately a PLAIN Control (not AspectRatioContainer/Center-
# Container): those report a minimum size derived from their child/own prior layout, which is what
# made the panel grow and bleed off-screen on reopen. A plain Control contributes ZERO minimum, so
# the preview can never push the panel bigger; the card inside is sized/centred manually by
# _fit_preview against the holder's real rect — bounded by construction, no size math.
func _make_preview_holder() -> Control:
	var holder := Control.new()
	holder.size_flags_horizontal = SIZE_EXPAND_FILL
	holder.size_flags_vertical = SIZE_EXPAND_FILL
	# A FIXED minimum height (stable, so it never bloats on reopen) so the card still reads when the
	# working area is short enough to scroll; on a tall window the holder expands well past this.
	holder.custom_minimum_size.y = 320.0 if _compact else 260.0
	holder.clip_contents = true
	holder.resized.connect(_fit_preview.bind(holder))
	return holder


# Empty the preview holder now (detach immediately, not deferred).
func _clear_preview(holder: Control) -> void:
	for child in holder.get_children():
		holder.remove_child(child)
		child.queue_free()


# Size the holder's card to the largest that keeps the card aspect and fits the holder, centred.
func _fit_preview(holder: Control) -> void:
	if holder.get_child_count() == 0:
		return
	var card := holder.get_child(0) as Control
	var avail := holder.size
	var w := minf(avail.x, avail.y / DeckUI.CARD_RATIO)
	var sz := Vector2(w, w * DeckUI.CARD_RATIO)
	card.size = sz
	card.position = (avail - sz) * 0.5


# Show `card_id`'s card filling `holder`. custom_minimum_size is zeroed (so it never grows the
# panel) and the card is positioned/sized by _fit_preview.
func _set_preview(holder: Control, card_id: String, interactive: bool) -> void:
	for child in holder.get_children():
		holder.remove_child(child)   # detach now so _fit_preview never sizes a stale, dying card
		child.queue_free()
	var card := DeckUI.card_thumbnail(card_id, 10.0, interactive)
	card.custom_minimum_size = Vector2.ZERO
	holder.add_child(card)
	_fit_preview(holder)


# ── Forge body layout (shared) ───────────────────────────────────────────────────────────

# Lays out a forge body so the card preview is the HERO and never fights the action button: on
# desktop the preview gets its OWN column (wider, full height) while the slots + status + button
# stack in the other column (slots up top, button pinned to the bottom). On compact it's a single
# stack (slots → preview → status → button). The preview holder expands to fill its column, so the
# card is sized as large as it can be.
func _assemble_forge(box: VBoxContainer, slots: Control, preview: Control, status: Label, button: Button) -> void:
	if _compact:
		box.add_child(slots)
		box.add_child(preview)
		box.add_child(status)
		box.add_child(button)
		return

	var row := HBoxContainer.new()
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	row.size_flags_vertical = SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 40)
	box.add_child(row)

	var controls := VBoxContainer.new()
	controls.size_flags_horizontal = SIZE_EXPAND_FILL
	controls.size_flags_vertical = SIZE_EXPAND_FILL
	controls.add_theme_constant_override("separation", 18)
	row.add_child(controls)
	controls.add_child(slots)
	var spacer := Control.new()   # keep slots up top and push status+button to the bottom
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	controls.add_child(spacer)
	controls.add_child(status)
	controls.add_child(button)

	var preview_col := VBoxContainer.new()
	preview_col.size_flags_horizontal = SIZE_EXPAND_FILL
	preview_col.size_flags_vertical = SIZE_EXPAND_FILL
	preview_col.size_flags_stretch_ratio = 1.3   # give the card column a bit more width
	row.add_child(preview_col)
	preview_col.add_child(preview)


func _make_forge_status() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 24 if _compact else 18)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 240.0   # keep autowrap from inflating min height
	return l


func _make_forge_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 32 if _compact else 28)
	b.custom_minimum_size = Vector2(0, 116) if _compact else Vector2(0, 88)
	b.size_flags_horizontal = SIZE_FILL
	b.pressed.connect(cb)
	return b


# ── Card Forge ──────────────────────────────────────────────────────────────────────────

func _card_forge_body(box: VBoxContainer) -> void:
	var slots := _slot_grid(2)
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

	_mint_preview = _make_preview_holder()
	_mint_status = _make_forge_status()
	_mint_btn = _make_forge_button("Craft Card", _on_mint)
	_assemble_forge(box, slots, _mint_preview, _mint_status, _mint_btn)


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
	var card_id := _staged_card_id()
	if card_id.is_empty():
		_clear_preview(_mint_preview)
		_mint_status.text = "Drop ingredients to design a card."
		_mint_btn.disabled = true
		return

	var card := CardData.get_card(card_id)
	var card_name: String = card.display_name if card != null else card_id
	_set_preview(_mint_preview, card_id, true)

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
	var slots := _slot_grid(3)

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

	_forge_preview = _make_preview_holder()
	_forge_status = _make_forge_status()
	_forge_btn = _make_forge_button("Forge King", _on_forge)
	_assemble_forge(box, slots, _forge_preview, _forge_status, _forge_btn)


func _staged_element(slot: DropSlot) -> String:
	return Materials.element_of(slot.staged_id) if not slot.staged_id.is_empty() else ""


func _update_forge() -> void:
	var a := _staged_element(_stone_slots[0])
	var b := _staged_element(_stone_slots[1])
	if a.is_empty() or b.is_empty():
		_clear_preview(_forge_preview)
		_forge_status.text = "Drop two stones to choose a King."
		_forge_btn.disabled = true
		return

	var king_id := Lab.king_id_for(a, b)
	var king := CardData.get_card(king_id)
	var king_name: String = king.display_name if king != null else king_id
	_set_preview(_forge_preview, king_id, false)

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
		var cols := 4 if _compact else 6
		var card_w := 92.0 if _compact else 74.0
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		# Fixed width sized for `cols` cards, so the auto-wrapping grid lays out in that many columns.
		scroll.custom_minimum_size = Vector2(cols * card_w + (cols - 1) * 10 + 4, minf(vp.y * 0.42, 360.0))
		scroll.size_flags_horizontal = SIZE_SHRINK_CENTER
		scroll.add_child(DeckUI.deck_grid(deck, card_w))
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
