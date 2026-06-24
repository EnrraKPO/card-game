extends Control

# The Forge. Drag one deck card onto another to COMBINE them; drag a charm chip onto a card to
# ENCHANT it. While dragging, the floating card carries a particle aura; hovering a valid target
# wraps it in a matching aura and a swirling vortex (ForgeLink) pulls motes between the two cards,
# while the side preview shows the result. Dropping on a valid target performs the merge; else cancels.

# One entry per deck card: { "card": DeckCard, "deck_idx": int, "data": CardData, "ui": CardUI,
# "item": ForgeDragItem (null for non-combinable cards, which can't be dragged but can be enchanted) }
var _entries: Array = []

# Must match the CardUI root custom_minimum_size in scenes/card_ui.tscn so the deck grid scales.
const CARD_SIZE := Vector2(160, 210)
# All particle VFX tuning lives in ForgeFX (ForgeFX.AURA / ForgeFX.LINK).

const OK_COLOR   := Color(0.4, 1.0, 0.55)
const BAD_COLOR  := Color(1.0, 0.4, 0.4)
const WARN_COLOR := Color(1.0, 0.6, 0.3)
const IDLE_COLOR := Color(0.7, 0.7, 0.8)

var _deck_grid: GridContainer
var _scroll: ScrollContainer
var _charm_row: HBoxContainer
var _compact := false
var _card_size := CARD_SIZE

# Right-hand preview panel.
var _preview_holder: Control
var _preview_status: Label

# Drag session (empty `_drag` == nothing in flight).
var _overlay: Control
var _drag: Dictionary = {}
var _follower: Control = null
var _follower_visual: Control = null   # the card/charm visual inside the follower (wobbles when linked)
var _follower_base_pos := Vector2.ZERO # its resting position (centred on the pointer)
var _wob_t := 0.0
var _wob := 0.0                         # eased 0→1 wobble strength (ramps with the connection)
var _aura: ForgeAura = null
var _target_aura: ForgeAura = null
var _target_item: Control = null       # the hovered target card's wrapper (wobbles while linked)
# The swirling vortex that connects the two cards while hovering a valid target.
var _link: ForgeLink = null
var _hover_idx: int = -1
# Carried from a valid combine hover so the drop doesn't recompute.
var _result_deck_card: DeckCard = null
# Floating result preview (the shared CardTooltip) that trails the cursor while a valid drop is
# hovered — the same combined card the sidebar shows, but right under the dragged cards.
var _drag_tip: Control = null
# The in-scene combine-confirmation overlay (null when closed). In-scene, not a Window, so its cards
# render in the main viewport with the same MSAA + mipmaps as the deck behind.
var _combine_modal: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# Rebuild the whole screen when the form-factor flips (desktop ↔ compact/touch), so the
	# layout switches variants instead of the canvas just scaling down. Re-armed each _ready.
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)
	_build_ui()
	_rebuild_deck()
	_rebuild_charms()
	_reset_preview()


func _build_ui() -> void:
	_compact = UIScale.is_compact()
	_card_size = Vector2(230, 302) if _compact else CARD_SIZE

	var s := ScreenUI.scaffold(self, "Forge")
	var root: VBoxContainer = s.root
	ScreenUI.attach_exits(_leave, s.header, s.footer)

	# ── Body ───────────────────────────────────────────────────────────────────
	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	# Left: scrollable deck grid + charm row beneath it.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	left.size_flags_vertical   = SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	body.add_child(left)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.resized.connect(_relayout_columns)
	left.add_child(scroll)
	_scroll = scroll

	_deck_grid = GridContainer.new()
	_deck_grid.columns = 3 if _compact else 4
	_deck_grid.add_theme_constant_override("h_separation", 12)
	_deck_grid.add_theme_constant_override("v_separation", 12)
	_deck_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_deck_grid)

	var charm_label := Label.new()
	charm_label.text = "Charms — drag one onto a card to enchant it"
	charm_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	charm_label.add_theme_font_size_override("font_size", 22 if _compact else 14)
	charm_label.modulate = IDLE_COLOR
	left.add_child(charm_label)

	_charm_row = HBoxContainer.new()
	_charm_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_charm_row.add_theme_constant_override("separation", 10)
	left.add_child(_charm_row)

	body.add_child(VSeparator.new())

	# Right: live preview panel.
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 420.0 if _compact else 360.0
	right.size_flags_vertical    = SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 18)
	body.add_child(right)

	var right_center := CenterContainer.new()
	right_center.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(right_center)

	var panel_vbox := VBoxContainer.new()
	panel_vbox.add_theme_constant_override("separation", 18)
	right_center.add_child(panel_vbox)

	_preview_holder = Control.new()
	_preview_holder.custom_minimum_size = _card_size
	_preview_holder.size_flags_horizontal = SIZE_SHRINK_CENTER
	panel_vbox.add_child(_preview_holder)

	_preview_status = Label.new()
	_preview_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_status.add_theme_font_size_override("font_size", 24 if _compact else 16)
	_preview_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_status.custom_minimum_size.x = 400.0 if _compact else 340.0
	panel_vbox.add_child(_preview_status)

	# Drag overlay: floats above everything, never eats input.
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_overlay)


# ── Deck display ────────────────────────────────────────────────────────────────

# Pack as many card columns as the scroll viewport can hold, so the grid fills the
# width instead of sitting at a fixed 4. Re-run whenever the viewport resizes.
func _relayout_columns() -> void:
	if _scroll == null or _deck_grid == null:
		return
	var bar := _scroll.get_v_scroll_bar()
	var bar_w := bar.size.x if bar.visible else 0.0
	var avail := _scroll.size.x - bar_w
	if avail <= 0.0:
		return
	var h_sep := float(_deck_grid.get_theme_constant("h_separation"))
	var cols := int(floor((avail + h_sep) / (_card_size.x + h_sep)))
	_deck_grid.columns = maxi(cols, 1)


func _rebuild_deck() -> void:
	_cancel_drag()
	for child in _deck_grid.get_children():
		child.queue_free()
	_entries.clear()
	_reset_preview()

	var deck: Array = GameData.current_run.deck.duplicate()
	for i in deck.size():
		var dc: DeckCard = deck[i]
		var data := CardData.get_card(dc.id)
		if data == null:
			continue
		var ui := CardUI.create(dc.make_instance())
		ui.draggable = false   # the Forge drives its own drag; CardUI's combat drag stays off
		ui.custom_minimum_size = _card_size

		var combinable := data.elements.size() > 0 or data.chess_pieces.size() > 0
		var entry_idx := _entries.size()

		# Every card is wrapped so it can be a drop TARGET (rect hit-test); only combinable cards
		# are draggable SOURCES. Non-combinable cards are dimmed but can still receive a charm.
		var item := ForgeDragItem.new()
		item.custom_minimum_size = _card_size
		item.setup(ui, {"kind": "card", "idx": entry_idx})
		# tooltip_text must be non-empty for Godot to fire the tooltip at all; tooltip_card then
		# upgrades it to the same rich preview shown in-game (CardTooltip).
		item.tooltip_text = data.description if not data.description.is_empty() else data.display_name
		item.tooltip_card = ui.card_instance
		if combinable:
			item.grab.connect(_begin_drag)
		else:
			ui.modulate = Color(1, 1, 1, 0.35)

		_entries.append({ "card": dc, "deck_idx": i, "data": data, "ui": ui, "item": item })
		_deck_grid.add_child(item)


# ── Charm inventory ──────────────────────────────────────────────────────────────

func _rebuild_charms() -> void:
	for child in _charm_row.get_children():
		child.queue_free()

	var counts: Dictionary = {}
	for charm_id: String in GameData.current_run.charms:
		counts[charm_id] = int(counts.get(charm_id, 0)) + 1

	if counts.is_empty():
		var empty := Label.new()
		empty.text = "(no charms)"
		empty.add_theme_font_size_override("font_size", 20 if _compact else 14)
		empty.modulate = Color(0.6, 0.6, 0.65)
		_charm_row.add_child(empty)
		return

	for charm_id: String in counts:
		_charm_row.add_child(_make_charm_item(charm_id, counts[charm_id]))


# A draggable charm chip (with ×N count). Dragging it onto a card enchants that card.
func _make_charm_item(charm_id: String, count: int) -> ForgeDragItem:
	var size := Vector2(84, 84) if _compact else Vector2(56, 56)
	var item := ForgeDragItem.new()
	item.custom_minimum_size = size
	item.setup(_make_charm_chip(charm_id, count, size), {"kind": "charm", "id": charm_id})
	var charm := CharmData.get_charm(charm_id)
	if charm != null:
		item.tooltip_text = "%s — %s" % [charm.display_name, charm.description]
	item.grab.connect(_begin_drag)
	return item


func _make_charm_chip(charm_id: String, count: int, size: Vector2) -> Control:
	var charm := CharmData.get_charm(charm_id)
	var chip := Panel.new()
	chip.custom_minimum_size = size
	var style := StyleBoxFlat.new()
	style.bg_color = (charm.color.lightened(0.1) if charm != null else Color(0.4, 0.4, 0.5))
	style.set_corner_radius_all(int(size.x * 0.5))
	style.set_border_width_all(2)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	chip.add_theme_stylebox_override("panel", style)
	if charm != null:
		chip.tooltip_text = "%s — %s" % [charm.display_name, charm.description]

	var lbl := Label.new()
	lbl.text = (charm.letter if charm != null else "✦")
	if count > 1:
		lbl.text += " ×%d" % count
	lbl.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 30 if _compact else 20)
	lbl.add_theme_color_override("font_color", Color(0.98, 0.98, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.mouse_filter = MOUSE_FILTER_IGNORE
	chip.add_child(lbl)
	return chip


# ── Drag session ──────────────────────────────────────────────────────────────

func _begin_drag(payload: Dictionary) -> void:
	if not _drag.is_empty():
		return
	_drag = payload
	_hover_idx = -1
	_result_deck_card = null

	var visual: Control = _make_follower_visual(payload)
	_follower = Control.new()
	_follower.mouse_filter = MOUSE_FILTER_IGNORE
	visual.position = -visual.custom_minimum_size * 0.5   # centre the visual on the pointer
	visual.pivot_offset = visual.custom_minimum_size * 0.5   # so wobble rotates around its centre
	_follower.add_child(visual)
	_overlay.add_child(_follower)
	_follower_visual = visual
	_follower_base_pos = visual.position
	_wob_t = 0.0
	_wob = 0.0

	var r := _aura_radii(payload)
	_aura = _make_aura(_source_color(payload), r.x, r.y)
	_follower.add_child(_aura)

	# Lift the dragged source out of the grid (visible = false, so the grid reflows to close the gap).
	if payload.kind == "card":
		_entries[payload.idx].item.visible = false

	_update_drag(get_global_mouse_position())


func _make_follower_visual(payload: Dictionary) -> Control:
	if payload.kind == "card":
		var inst: CardInstance = _entries[payload.idx].card.make_instance()
		var ui := CardUI.create(inst)
		ui.custom_minimum_size = _card_size
		ui.size = _card_size
		ui.modulate.a = 0.85
		return ui
	var size := Vector2(96, 96) if _compact else Vector2(64, 64)
	var chip := _make_charm_chip(payload.id, 1, size)
	chip.custom_minimum_size = size
	chip.size = size
	return chip


# Drives the dragged card's wobble: it eases in while a link is active, out when it breaks.
func _process(delta: float) -> void:
	if _follower_visual == null:
		return
	_auto_scroll(delta)
	var cfg := ForgeFX.CARD
	var connected := 1.0 if _link != null else 0.0
	_wob = lerpf(_wob, connected, clampf(delta * float(cfg["wobble_ease"]), 0.0, 1.0))
	if _wob < 0.001:
		_follower_visual.rotation = 0.0
		_follower_visual.position = _follower_base_pos
		if _target_item != null:
			_target_item.rotation = 0.0
		return
	_wob_t += delta
	var freq := float(cfg["wobble_freq"])
	var rot := _wob * float(cfg["wobble_rot"])
	_follower_visual.rotation = rot * sin(_wob_t * freq)
	var sway := _wob * float(cfg["wobble_sway"])
	_follower_visual.position = _follower_base_pos + Vector2(sway * sin(_wob_t * freq * 0.7), sway * sin(_wob_t * freq * 1.3))
	# The target card wobbles too (rotation only — it lives in the grid, which manages its position),
	# slightly out of phase so the pair feels independently alive.
	if _target_item != null:
		_target_item.rotation = rot * sin(_wob_t * freq + PI * 0.5)


func _input(event: InputEvent) -> void:
	# While the confirm overlay is up, Esc cancels it (consumed here so Nav doesn't also fire).
	if _combine_modal != null:
		if event.is_action_pressed("ui_cancel"):
			_close_combine_modal()
			get_viewport().set_input_as_handled()
		return
	if _drag.is_empty():
		return
	if event is InputEventMouseMotion:
		_update_drag(get_global_mouse_position())
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_resolve_drag()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_cancel_drag()   # right-click aborts the drag without merging
			get_viewport().set_input_as_handled()


func _update_drag(global_pos: Vector2) -> void:
	if _follower == null:
		return
	_follower.global_position = global_pos
	_set_hover(_target_under(global_pos))
	_position_drag_tip(global_pos)
	if _link != null and _hover_idx >= 0:
		# Connect the two cards' orbit rings, in overlay-local space.
		var inv := _overlay.get_global_transform().affine_inverse()
		var tgt: Control = _entries[_hover_idx].item
		var rr := _card_aura_radii()
		_link.set_endpoints(inv * global_pos, inv * tgt.get_global_rect().get_center(), rr.x, rr.y)


# While dragging, ease the deck scroll up/down when the pointer nears the top/bottom edge,
# so cards out of view can be reached without letting go. Hover/link are refreshed as it shifts.
func _auto_scroll(delta: float) -> void:
	if _scroll == null:
		return
	var rect := _scroll.get_global_rect()
	var zone := 140.0 if _compact else 90.0   # edge band that triggers scrolling
	var speed := 1100.0                        # px/sec at the very edge
	var y := get_global_mouse_position().y
	var dv := 0.0
	if y < rect.position.y + zone:
		dv = -(1.0 - clampf((y - rect.position.y) / zone, 0.0, 1.0))
	elif y > rect.end.y - zone:
		dv = 1.0 - clampf((rect.end.y - y) / zone, 0.0, 1.0)
	if dv == 0.0:
		return
	var before := _scroll.scroll_vertical
	_scroll.scroll_vertical = before + int(dv * speed * delta)
	if _scroll.scroll_vertical != before:
		_update_drag(get_global_mouse_position())   # cards moved under the cursor — re-evaluate


# The index of the deck card under `global_pos`, excluding the dragged source itself; -1 if none.
func _target_under(global_pos: Vector2) -> int:
	for i in _entries.size():
		if _drag.get("kind") == "card" and int(_drag.get("idx", -1)) == i:
			continue
		var item: Control = _entries[i].item
		if item != null and item.get_global_rect().has_point(global_pos):
			return i
	return -1


func _set_hover(target_idx: int) -> void:
	if target_idx == _hover_idx:
		return
	_clear_hover_visuals()
	_hover_idx = target_idx
	if target_idx < 0:
		_reset_preview()
		return

	var verdict := _evaluate_target(_drag, target_idx)
	_result_deck_card = verdict.get("result_dc", null)
	_show_preview(verdict.get("preview", null), str(verdict.get("status", "")), verdict.get("color", IDLE_COLOR))
	_show_drag_tip(verdict.get("preview", null))

	if bool(verdict.get("ok", false)):
		var col: Color = verdict.get("color", OK_COLOR)
		# Both halos whirl faster/brighter and a swirling vortex pulls motes between the two cards.
		var connect_intensity := float(ForgeFX.AURA["connect_intensity"])
		_aura.set_intensity(connect_intensity)
		var inv := _overlay.get_global_transform().affine_inverse()
		var center := inv * (_entries[target_idx].item as Control).get_global_rect().get_center()
		var rr := _card_aura_radii()
		_target_aura = _make_aura(col, rr.x, rr.y)
		_target_aura.position = center
		_target_aura.set_intensity(connect_intensity)
		_overlay.add_child(_target_aura)
		_link = ForgeLink.new()
		_link.setup(col)
		_link.set_endpoints(inv * _follower.global_position, center, rr.x, rr.y)
		_overlay.add_child(_link)
		# Mark the target card so _process can wobble it too (rotating around its centre).
		_target_item = _entries[target_idx].item
		_target_item.pivot_offset = _target_item.size * 0.5


func _clear_hover_visuals() -> void:
	if _aura != null:
		_aura.set_intensity(1.0)
	if _target_aura != null:
		_target_aura.queue_free()
		_target_aura = null
	if _link != null:
		_link.queue_free()
		_link = null
	if _target_item != null:
		_target_item.rotation = 0.0
		_target_item = null
	_hide_drag_tip()


func _resolve_drag() -> void:
	var payload := _drag
	var hover := _hover_idx
	var did := hover >= 0 and bool(_evaluate_target(payload, hover).get("ok", false))
	# Capture what's needed before teardown clears state.
	var src_idx: int = int(payload.get("idx", -1))
	var charm_id: String = str(payload.get("id", ""))
	var result_dc: DeckCard = _result_deck_card
	_cancel_drag()
	if not did:
		return
	if payload.get("kind") == "card":
		# Combining destroys both originals, so confirm intent before committing.
		_confirm_combine(src_idx, hover, result_dc)
	else:
		_do_enchant(charm_id, hover)


# A modal showing the two cards being spent and the card they forge into (all with descriptions),
# gated behind Cancel/Forge. Built as an in-scene overlay (not a Window) so its cards share the deck's
# MSAA + mipmaps. Indices stay valid: the dim swallows input so nothing reshuffles the deck, and the
# deck isn't rebuilt until the user confirms.
func _confirm_combine(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	if result_dc == null or src_idx < 0 or tgt_idx < 0:
		return
	var a_inst: CardInstance = (_entries[src_idx].card as DeckCard).make_instance()
	var b_inst: CardInstance = (_entries[tgt_idx].card as DeckCard).make_instance()
	var result_inst := result_dc.make_instance()

	# Full-screen dim that blocks the deck behind; a click on it (outside the panel) cancels.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close_combine_modal())
	add_child(dim)
	_combine_modal = dim

	# CenterContainer centres the panel; empty space stays input-transparent so it falls to the dim.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	dim.add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.15, 0.98)
	style.set_border_width_all(2)
	style.border_color = Color(0.45, 0.45, 0.6)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(28 if _compact else 18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18 if _compact else 12)
	panel.add_child(col)

	var prompt := Label.new()
	prompt.text = "Forge these two cards into one? Both originals are consumed."
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD
	prompt.add_theme_font_size_override("font_size", 24 if _compact else 16)
	col.add_child(prompt)

	var cs := Vector2(190, 249) if _compact else Vector2(150, 196)   # keeps the 260×340 aspect
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18 if _compact else 14)
	row.add_child(_make_combine_cell(a_inst, cs))
	row.add_child(_make_combine_op("+", cs.y))
	row.add_child(_make_combine_cell(b_inst, cs))
	row.add_child(_make_combine_op("→", cs.y))
	row.add_child(_make_combine_cell(result_inst, cs))
	col.add_child(row)

	var buttons := HBoxContainer.new()
	buttons.size_flags_horizontal = SIZE_EXPAND_FILL   # span the panel so the two targets are wide
	buttons.add_theme_constant_override("separation", 24 if _compact else 16)
	var cancel_btn := _modal_button("Cancel")
	var forge_btn := _modal_button("Forge")
	cancel_btn.pressed.connect(_close_combine_modal)
	forge_btn.pressed.connect(func() -> void:
		_do_combine(src_idx, tgt_idx, result_dc)
		_close_combine_modal())
	buttons.add_child(cancel_btn)
	buttons.add_child(forge_btn)
	col.add_child(buttons)


func _close_combine_modal() -> void:
	if _combine_modal != null:
		_combine_modal.queue_free()
		_combine_modal = null


# A big, easy-to-hit modal button. Each one EXPAND_FILLs half the button row, so on top of the
# generous min height they stretch wide across the panel — no fiddly aiming for confirm/cancel.
func _modal_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(300, 120) if _compact else Vector2(220, 64)
	b.add_theme_font_size_override("font_size", 40 if _compact else 26)
	return b


# One column of the combine modal: an enlarged card over its name + wrapped description. Cells FILL
# the row's height (default) so every card sits flush at the top and the three line up, regardless of
# how tall each description wraps.
func _make_combine_cell(inst: CardInstance, cs: Vector2) -> Control:
	var cell := VBoxContainer.new()
	cell.size_flags_vertical = SIZE_FILL
	cell.add_theme_constant_override("separation", 6)

	var holder := Control.new()
	holder.custom_minimum_size = cs
	holder.size_flags_horizontal = SIZE_SHRINK_CENTER
	holder.size_flags_vertical = SIZE_SHRINK_BEGIN   # keep the card at its size, pinned to the top
	var card := CardUI.create(inst)
	card.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	card.mouse_filter = MOUSE_FILTER_IGNORE
	holder.add_child(card)
	cell.add_child(holder)

	var name_lbl := Label.new()
	name_lbl.text = inst.data.display_name
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 20 if _compact else 16)
	cell.add_child(name_lbl)

	var desc := inst.data.description
	if not desc.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = desc
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc_lbl.custom_minimum_size.x = 300.0 if _compact else 220.0   # wider than the card so text wraps to fewer lines
		desc_lbl.add_theme_font_size_override("font_size", 18 if _compact else 14)
		desc_lbl.modulate = Color(0.82, 0.82, 0.9)
		cell.add_child(desc_lbl)

	return cell


# The "+" / "→" glyph between cells. Sized to the card's height and pinned to the top so the glyph
# centres on the cards (not on the taller, description-driven cell).
func _make_combine_op(glyph: String, card_h: float) -> Control:
	var lbl := Label.new()
	lbl.text = glyph
	lbl.custom_minimum_size.y = card_h
	lbl.size_flags_vertical = SIZE_SHRINK_BEGIN
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 36 if _compact else 28)
	lbl.modulate = Color(0.7, 0.7, 0.8)
	return lbl


# Tears down the in-flight drag visuals and restores the hidden source. Safe to call anytime.
func _cancel_drag() -> void:
	_clear_hover_visuals()
	if _follower != null:
		_follower.queue_free()
		_follower = null
	_follower_visual = null
	_aura = null
	if not _drag.is_empty() and _drag.get("kind") == "card":
		var idx := int(_drag.get("idx", -1))
		if idx >= 0 and idx < _entries.size() and _entries[idx].item != null:
			_entries[idx].item.visible = true   # drop it back into the grid
	_drag = {}
	_hover_idx = -1
	_result_deck_card = null


# ── Validity + preview ──────────────────────────────────────────────────────────

# Evaluates dropping `payload` on the card at `target_idx`. Returns:
#   { ok, status, color, preview: CardInstance|null, result_dc: DeckCard|null }
func _evaluate_target(payload: Dictionary, target_idx: int) -> Dictionary:
	var tgt: Dictionary = _entries[target_idx]
	if payload.kind == "card":
		var a: CardData = _entries[int(payload.idx)].data
		var b: CardData = tgt.data
		if not CardData.can_combine(a, b):
			return {"ok": false, "status": "Exceeds the combination limit (2 elements + 2 chess pieces)", "color": BAD_COLOR}
		var result := CardData.combine(a, b)
		var rdc := DeckCard.make(result.id)
		for charm_id: String in _merged_parent_charms([_entries[int(payload.idx)].card, tgt.card], result):
			rdc.add_charm(charm_id)
		return {"ok": true, "status": "Result: %s" % result.display_name, "color": OK_COLOR,
			"preview": rdc.make_instance(), "result_dc": rdc}
	else:
		var charm := CharmData.get_charm(str(payload.id))
		var data: CardData = tgt.data
		if charm == null:
			return {"ok": false}
		if not charm.can_attach_to(data):
			return {"ok": false, "status": "%s can't bear the %s charm." % [data.display_name, charm.display_name], "color": BAD_COLOR}
		if str(payload.id) in (tgt.card as DeckCard).charms:
			return {"ok": false, "status": "%s already bears %s." % [data.display_name, charm.display_name], "color": WARN_COLOR}
		var preview_dc := (tgt.card as DeckCard).clone()
		preview_dc.add_charm(str(payload.id))
		return {"ok": true, "status": "Enchant %s with %s" % [data.display_name, charm.display_name],
			"color": OK_COLOR, "preview": preview_dc.make_instance()}


# Union of both parents' charms still valid on the combined result.
func _merged_parent_charms(parents: Array, result_card: CardData) -> Array:
	var out: Array = []
	for dc: DeckCard in parents:
		for charm_id: String in dc.charms:
			var charm := CharmData.get_charm(charm_id)
			if charm != null and charm.can_attach_to(result_card) and charm_id not in out:
				out.append(charm_id)
	return out


func _show_preview(inst: CardInstance, status: String, color: Color) -> void:
	for child in _preview_holder.get_children():
		child.queue_free()
	if inst != null:
		var ui := CardUI.create(inst)
		ui.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		ui.mouse_filter = MOUSE_FILTER_IGNORE
		_preview_holder.add_child(ui)
	_preview_status.text = status
	_preview_status.modulate = color


func _reset_preview() -> void:
	for child in _preview_holder.get_children():
		child.queue_free()
	_preview_status.text = "Drag a card onto another to combine them,\nor drag a charm onto a card to enchant it."
	_preview_status.modulate = IDLE_COLOR


# Floats the shared CardTooltip of the would-be result next to the cursor while dragging, so the
# combined card reads right where the action is (mirrors the sidebar preview). `inst` null = hide.
func _show_drag_tip(inst: CardInstance) -> void:
	_hide_drag_tip()
	if inst == null:
		return
	var tip := CardTooltip.build(inst)
	if tip == null:
		return
	tip.mouse_filter = MOUSE_FILTER_IGNORE   # decorative — never intercept the drag
	_overlay.add_child(tip)
	_drag_tip = tip
	_position_drag_tip(get_global_mouse_position())


func _hide_drag_tip() -> void:
	if _drag_tip != null:
		_drag_tip.queue_free()
		_drag_tip = null


# Trails the tip beside the pointer, clearing the dragged card, and clamps it on-screen (flips to
# the cursor's left if it would overflow the right edge).
func _position_drag_tip(global_pos: Vector2) -> void:
	if _drag_tip == null:
		return
	var vp := get_viewport_rect().size
	var ts := _drag_tip.get_combined_minimum_size()
	var gap := _card_size.x * 0.6 + 24.0   # clear the half-card-wide follower under the cursor
	var margin := 16.0
	var x := global_pos.x + gap
	if x + ts.x + margin > vp.x:
		x = global_pos.x - gap - ts.x
	x = clampf(x, margin, maxf(margin, vp.x - ts.x - margin))
	var y := clampf(global_pos.y - ts.y * 0.5, margin, maxf(margin, vp.y - ts.y - margin))
	_drag_tip.global_position = Vector2(x, y)


# ── Apply ──────────────────────────────────────────────────────────────────────

func _do_combine(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	if result_dc == null or src_idx < 0:
		return
	var src_deck: int = int(_entries[src_idx].deck_idx)
	var tgt_deck: int = int(_entries[tgt_idx].deck_idx)
	# Remove both source cards highest-deck-index-first to avoid index shifting.
	var deck_indices := [src_deck, tgt_deck]
	deck_indices.sort()
	for i in range(deck_indices.size() - 1, -1, -1):
		GameData.current_run.deck.remove_at(deck_indices[i])
	# Drop the result into the TARGET card's slot (shift left one if the source sat before it).
	var insert_at := tgt_deck - (1 if src_deck < tgt_deck else 0)
	insert_at = clampi(insert_at, 0, GameData.current_run.deck.size())
	GameData.current_run.deck.insert(insert_at, result_dc)
	GameData.save_run()
	_rebuild_deck()


func _do_enchant(charm_id: String, tgt_idx: int) -> void:
	var dc: DeckCard = _entries[tgt_idx].card
	var data: CardData = _entries[tgt_idx].data
	dc.add_charm(charm_id)
	GameData.current_run.charms.erase(charm_id)
	GameData.save_run()
	_rebuild_deck()
	_rebuild_charms()
	_show_preview(dc.make_instance(), "Enchanted %s with %s!" % [data.display_name, CharmData.get_charm(charm_id).display_name], OK_COLOR)


# ── Particles ──────────────────────────────────────────────────────────────────

# Half-extents of the particle path. Start from the card's half-size, scale it by
# ForgeFX.AURA.radius_scale (the main handle — 1.0 = on the edge, >1 = wider, <1 = tighter), then
# add ForgeFX.AURA.margin for a flat px nudge on top. Tweak `radius_scale` to resize the ring.
func _card_aura_radii() -> Vector2:
	var scale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	return Vector2(_card_size.x * 0.5 * scale + margin, _card_size.y * 0.5 * scale + margin)


func _aura_radii(payload: Dictionary) -> Vector2:
	if payload.kind == "card":
		return _card_aura_radii()
	var scale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	return Vector2(36.0 * scale + margin, 36.0 * scale + margin)


# A hand-drawn halo that swirls around the card — see ForgeAura (tuning in ForgeFX.AURA).
func _make_aura(color: Color, rx: float, ry: float) -> ForgeAura:
	var a := ForgeAura.new()
	a.setup(rx, ry, color)
	return a


func _source_color(payload: Dictionary) -> Color:
	if payload.kind == "card":
		var data: CardData = _entries[int(payload.idx)].data
		if not data.elements.is_empty():
			var info: Dictionary = CardUI.COMP_VISUALS.get(data.elements[0], {})
			return info.get("color", Color(0.7, 0.8, 1.0))
		if not data.chess_pieces.is_empty():
			var cinfo: Dictionary = CardUI.COMP_VISUALS.get(data.chess_pieces[0], {})
			return cinfo.get("color", Color(0.7, 0.8, 1.0))
		return Color(0.7, 0.8, 1.0)
	var charm := CharmData.get_charm(str(payload.id))
	return charm.color if charm != null else Color(0.8, 0.7, 1.0)


func _leave() -> void:
	get_tree().change_scene_to_file("res://scenes/map.tscn")
