class_name EnemyHandOverlay
extends Control

# DEBUG ONLY: the cards the CPU is actually holding, laid out face-up over a scrim. Opened by
# clicking the EnemyIntel widget in combat's action column; there is no path to it in a normal
# build (EnemyIntel only takes the click when DebugConfig.enabled()), because knowing the
# opponent's hand is a development tool, not a game affordance.
#
# Built in code like every other overlay here, and dismissed the same way as CardInspector:
# any press closes it, with the closing click consumed whole (press hides, release frees) so it
# cannot leak through to the board underneath.

const MARGIN := 48.0
const GAP := 14.0
const PANEL_PAD := 18.0
const CARD_W_MAX := 300.0    # past this the card art is just upscaled pixels (CardInspector's
							  # DESKTOP_MAX_SCALE reasoning, at this overlay's smaller scale)
const CARD_W_MIN := 90.0
const MAX_ROWS := 4          # a hand deeper than this wraps into smaller cards, not more rows
const CHROME_H := 120.0      # the title and close hint that flank the panel, plus separations


var _side: CombatSide
var _layer: CanvasLayer
var _dismissing := false


static func open(host: Node, side: CombatSide) -> void:
	if side == null or host == null or not host.is_inside_tree() or not DebugConfig.enabled():
		return
	var ov := EnemyHandOverlay.new()
	ov._side = side
	var layer := CanvasLayer.new()
	layer.layer = 200
	ov._layer = layer
	layer.add_child(ov)
	host.get_viewport().add_child(layer)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.85)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var body := MarginContainer.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "right", "top", "bottom"]:
		body.add_theme_constant_override("margin_" + edge, int(MARGIN))
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(body)

	# Centred as a block: the panel hugs the cards (see _cards_panel), so the overlay reads as
	# one object floating on the scrim instead of an empty frame with a row stuck to its top.
	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(centre)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(col)

	var title := Label.new()
	title.text = Loc.t("combat.enemy_hand_title", {"n": _side.hand.size(),
			"pile": _side.draw_pile.size()})
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", EnemyIntel.TAG_COLOR)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)

	col.add_child(_cards_panel())

	var hint := Label.new()
	hint.text = Loc.t("common.tap_close") if DisplayServer.is_touchscreen_available() \
			else Loc.t("common.click_close")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(hint)


# The hand itself, in a framed panel so it reads as one object against the scrim. Cards are
# display-only (MOUSE_FILTER_IGNORE): the overlay's own dismissal owns every press, and a
# nested inspector opened from a debug peek is a rabbit hole nobody asked for.
func _cards_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = CardTooltip.BG_COLOR
	style.set_border_width_all(2)
	style.border_color = CardTooltip.BORDER_COLOR
	style.set_corner_radius_all(12)
	style.set_content_margin_all(PANEL_PAD)
	panel.add_theme_stylebox_override("panel", style)

	if _side.hand.is_empty():
		var empty := Label.new()
		empty.text = Loc.t("combat.enemy_hand_empty")
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 22)
		empty.add_theme_color_override("font_color", Color(0.8, 0.8, 0.86))
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(empty)
		return panel

	# A GRID at the solved shape, not a free-flowing wrap: the solve already decided how many
	# cards go per row, and letting the flow re-wrap them would undo it.
	var shape := _solve_shape(_side.hand.size())
	var grid := GridContainer.new()
	grid.columns = int(shape.z)
	grid.add_theme_constant_override("h_separation", int(GAP))
	grid.add_theme_constant_override("v_separation", int(GAP))
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(grid)

	var card_size := Vector2(shape.x, shape.y)
	for inst: CardInstance in _side.hand:
		var card := CardUI.create(inst, true)
		card.custom_minimum_size = card_size
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(card)
	return panel


# The biggest cards that fit, and how many go per row — the board's own sizing idea
# (Combat._resize_board) at overlay scale: try each row count and keep whichever yields the
# largest card, so four cards come up big and a hoarded twelve stay legible instead of the
# whole thing being pinned to one hand-picked width. Returns (card_w, card_h, per_row).
func _solve_shape(count: int) -> Vector3:
	var aspect := CardTooltip.PREVIEW_SIZE.y / CardTooltip.PREVIEW_SIZE.x
	var vp := get_viewport_rect().size
	var avail_w := vp.x - 2.0 * MARGIN - 2.0 * PANEL_PAD
	var avail_h := vp.y - 2.0 * MARGIN - 2.0 * PANEL_PAD - CHROME_H
	var best_w := CARD_W_MIN
	var best_cols := count
	for rows in range(1, MAX_ROWS + 1):
		var cols := int(ceil(float(count) / float(rows)))
		var by_width := (avail_w - (cols - 1) * GAP) / float(cols)
		var by_height := ((avail_h - (rows - 1) * GAP) / float(rows)) / aspect
		var w := minf(minf(by_width, by_height), CARD_W_MAX)
		if w > best_w:
			best_w = w
			best_cols = cols
		if cols <= 1:
			break   # one card per row is as few as it gets; deeper row counts repeat it
	best_w = maxf(best_w, CARD_W_MIN)
	return Vector3(floorf(best_w), floorf(best_w * aspect), float(maxi(best_cols, 1)))


# Any press dismisses; the closing click is consumed whole so its release cannot reach the
# combat screen behind (the same contract CardInspector documents).
func _input(event: InputEvent) -> void:
	var is_press := (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
	var is_release := (event is InputEventMouseButton and not (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed)
	if is_press and not _dismissing:
		_dismissing = true
		visible = false
		get_viewport().set_input_as_handled()
	elif is_release and _dismissing:
		get_viewport().set_input_as_handled()
		if _layer != null:
			_layer.queue_free()
