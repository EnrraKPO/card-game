class_name CardInspector
extends Control

# Full-screen, tap-to-dismiss card detail overlay: the in-depth view of a card. Opened by
# long-press on touch (hover tooltips don't exist there) and by RIGHT-CLICK on desktop. The card
# itself sits dead-centre on screen (blown up to fill the height), with its stat glossary flanking
# it on the LEFT and its detail column on the RIGHT — the card is the fixed anchor, so toggling the
# stat descriptions never shifts it. Over a dimmed scrim; any press (bar the one toggle) closes it.
# Built in code (no scene), mirroring the rest of the UI. See CardUI._gui_input and CardTooltip
# (build_details / build_stat_guide, reused here).

const MARGIN := 40.0       # breathing room between the content and the screen edges
const HINT_BLOCK := 46.0   # the close-hint row + its separation, reserved under the content
const GAP := 30.0          # gap between the centred card and each flanking column
const DETAIL_PAD := 14.0   # padding inside the detail panel

# Desktop cap: the card frame/nameplate are authored at the canvas's own 260×340, so past ~2×
# the preview's textures are just upscaled pixels (fonts stay crisp — they're MSDF). Touch gets
# no cap: on a phone, readability under a thumb outweighs texel-perfect frame art.
const DESKTOP_MAX_SCALE := 2.0

var _inst: CardInstance
var _show_cost: bool
var _layer: CanvasLayer
var _dismissing := false
# The stat-guide "Show Stat Descriptions" preference — remembered across opens within a session
# (a static), so a player who collapses it keeps it collapsed on the next card they inspect.
static var _show_descriptions := true
var _toggle: Control = null   # the current layout's toggle; a press on it must NOT dismiss
# Scale is fixed ONCE at open (sized so the tallest column fits the screen) and reused for every
# rebuild, so toggling descriptions never resizes or shifts the card — the layout stays rock-still.
var _scale := 0.0
var _content: Control = null  # the laid-out card + flanking columns; rebuilt in place on toggle


# Opens the inspector for `inst` above everything else (combat HUD, menus). `host` only supplies
# the viewport; the overlay parents to that viewport (not the originating card) so it survives
# the card and stays inside whatever viewport the game runs in (window, embedded, render harness).
static func open(host: Node, inst: CardInstance, show_cost := true) -> void:
	if inst == null or host == null or not host.is_inside_tree():
		return
	var insp := CardInspector.new()
	insp._inst = inst
	insp._show_cost = show_cost
	var layer := CanvasLayer.new()
	layer.layer = 200
	insp._layer = layer
	layer.add_child(insp)
	host.get_viewport().add_child(layer)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.85)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	_scale = await _compute_scale()
	if _dismissing or not is_inside_tree():
		return
	_layout()


# Picks the one scale used for the whole session of this overlay: measure the two text columns'
# natural heights (at scale 1) and size the card so the TALLEST of card/stats/details just fills
# the screen height. Fixed here so a later toggle can rebuild without anything changing size.
func _compute_scale() -> float:
	var vp := get_viewport_rect().size
	var avail_h := vp.y - 2.0 * MARGIN - HINT_BLOCK

	var guide: Control = null
	if CardTooltip.has_stat_guide(_inst):
		guide = CardTooltip.build_stat_guide(_inst, 1.0, true)
		guide.modulate.a = 0.0
		add_child(guide)
	var details := _details_panel(1.0)
	details.modulate.a = 0.0
	add_child(details)
	await get_tree().process_frame

	var tallest := CardTooltip.PREVIEW_SIZE.y
	if guide != null:
		tallest = maxf(tallest, guide.get_combined_minimum_size().y)
		guide.queue_free()
	tallest = maxf(tallest, details.get_combined_minimum_size().y)
	details.queue_free()

	var by_h := avail_h / tallest
	# Width: two equal side columns + the card + two gaps must fit between the margins.
	var side_w := maxf(CardTooltip.GUIDE_WIDTH, CardTooltip.COLUMN_WIDTH + 2.0 * DETAIL_PAD)
	var by_w := (vp.x - 2.0 * MARGIN) / (2.0 * side_w + CardTooltip.PREVIEW_SIZE.x + 2.0 * GAP)
	var s := minf(by_h, by_w)
	if not DisplayServer.is_touchscreen_available():
		s = minf(s, DESKTOP_MAX_SCALE)
	return maxf(1.0, s)


# Lays the overlay out as three columns whose CENTRE is the card: two equal expand-fill side cells
# flank a shrink-centred card, so the card sits dead-centre on screen and stays put no matter what
# the sides hold. Stats hug the card's left (top-aligned); details hug its right. Rebuilt wholesale
# on toggle — at the fixed _scale, so the card never moves.
func _layout() -> void:
	if _content != null:
		_content.queue_free()
	_toggle = null
	var s := _scale

	_content = MarginContainer.new()
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		_content.add_theme_constant_override("margin_" + side, int(MARGIN))
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_content)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(outer)

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", int(GAP))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(row)

	# Left cell: a spacer shoves the stat column right, hugging the card; top-aligned so the toggle
	# sits at the top and stays there whether the descriptions are shown or collapsed.
	var left := HBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(_hspacer())
	if CardTooltip.has_stat_guide(_inst):
		var stats := CardTooltip.build_stat_guide(_inst, s, _show_descriptions)
		stats.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		left.add_child(stats)
	row.add_child(left)

	# The card — the fixed centre of the whole overlay.
	var card := CardUI.create(_inst, _show_cost)
	card.custom_minimum_size = CardTooltip.PREVIEW_SIZE * s
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if CardTooltip.has_stat_guide(_inst) and card.has_method("set_stat_tooltips"):
		card.set_stat_tooltips(CardTooltip.stat_tips(_inst))
	row.add_child(card)

	# Right cell: details hug the card's right, top-aligned, a spacer taking the slack.
	var right := HBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var details := _details_panel(s)
	details.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.add_child(details)
	right.add_child(_hspacer())
	row.add_child(right)

	var hint := Label.new()
	hint.text = Loc.t("common.tap_close") if DisplayServer.is_touchscreen_available() \
			else Loc.t("common.click_close")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	outer.add_child(hint)

	var toggles := _content.find_children("*", "CheckButton", true, false)
	var btn := toggles[0] as BaseButton if not toggles.is_empty() else null
	if btn != null:
		_toggle = btn
		btn.toggled.connect(_on_desc_toggled)


# The detail column wrapped in a dark rounded panel, so it reads as its own info card against the
# scrim (the card carries its own frame; the stat notes carry their own borders).
func _details_panel(s: float) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CardTooltip.BG_COLOR
	style.set_border_width_all(1)
	style.border_color = CardTooltip.BORDER_COLOR
	style.set_corner_radius_all(int(8.0 * s))
	style.set_content_margin_all(DETAIL_PAD * s)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(CardTooltip.build_details(_inst, s))
	return panel


func _hspacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# Flip the remembered preference and re-lay-out (at the fixed _scale, so nothing resizes/moves).
func _on_desc_toggled(pressed: bool) -> void:
	_show_descriptions = pressed
	_layout()


# Any press anywhere dismisses. _input runs ahead of GUI routing, so this fires even when the tap
# lands on the card panel's own labels. Opening-gesture releases are ignored so the long-press that
# opened the inspector (the finger is still down at open time) doesn't immediately close it again.
# The CLOSING click is consumed whole — hidden on the press, freed on the matching release, both
# marked handled — so the release can't leak into whatever sits underneath (e.g. Combat's
# outside-click dismissal would also collapse the hand's inspect view behind the overlay).
func _input(event: InputEvent) -> void:
	var is_press := (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
	var is_release := (event is InputEventMouseButton and not (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed)
	# The stat-descriptions toggle is the one interactive control on the overlay: a press ON it must
	# reach the button (toggle + rebuild) instead of dismissing. Hit-test its rect directly — this
	# runs before GUI routing, and works for both mouse and touch (gui hover isn't set on touch).
	if is_press and _toggle != null and is_instance_valid(_toggle) and _toggle.is_visible_in_tree():
		var pos: Vector2 = (event as InputEventMouseButton).position if event is InputEventMouseButton \
			else (event as InputEventScreenTouch).position
		if _toggle.get_global_rect().has_point(pos):
			return
	if is_press and not _dismissing:
		_dismissing = true
		visible = false
		get_viewport().set_input_as_handled()
	elif is_release and _dismissing:
		get_viewport().set_input_as_handled()
		if _layer != null:
			_layer.queue_free()
