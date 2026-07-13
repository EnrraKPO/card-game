class_name CardInspector
extends Control

# Full-screen, tap-to-dismiss card detail overlay: the in-depth view of a card. Opened by
# long-press on touch (hover tooltips don't exist there) and by RIGHT-CLICK on desktop — the
# same shared CardTooltip panel (incl. the abilities section), scaled up to span the screen
# height minus margins (readability is the whole point, especially on mobile) and centred over
# a dimmed scrim. Any press anywhere closes it. Built in code (no scene), mirroring the rest of
# the UI. See CardUI._gui_input.

const MARGIN := 36.0       # breathing room between the panel and the screen edges
const HINT_BLOCK := 46.0   # the close-hint row + its separation, reserved under the panel

# Desktop cap: the card frame/nameplate are authored at the canvas's own 260×340, so past ~2×
# the preview's textures are just upscaled pixels (fonts stay crisp — they're MSDF). Touch gets
# no cap: on a phone, readability under a thumb outweighs texel-perfect frame art, so the panel
# fills the screen height there.
const DESKTOP_MAX_SCALE := 2.0

var _inst: CardInstance
var _show_cost: bool
var _layer: CanvasLayer
var _dismissing := false
var _col: VBoxContainer
var _panel: Control = null


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
	scrim.color = Color(0, 0, 0, 0.66)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_col = VBoxContainer.new()
	_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_col.add_theme_constant_override("separation", 14)
	center.add_child(_col)

	var hint := Label.new()
	hint.text = "Tap anywhere to close" if DisplayServer.is_touchscreen_available() \
			else "Click anywhere to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	_col.add_child(hint)

	_mount_panel(_fit_scale())

	# The estimate assumes the card preview is the panel's tallest part. A content-heavy detail
	# column (long description, many abilities/charms/statuses) can outgrow it — measure the
	# real panel after a layout pass and rebuild once at the corrected factor.
	await get_tree().process_frame
	if _dismissing or not is_inside_tree() or _panel == null:
		return
	var target := _target_h()
	if _panel.size.y > target and _panel.size.y > 0.0:
		_mount_panel(_fit_scale() * target / _panel.size.y)


# (Re)builds the detail panel at `scale`, keeping it above the hint row.
func _mount_panel(scale: float) -> void:
	if _panel != null:
		_panel.queue_free()
	_panel = CardTooltip.build(_inst, _show_cost, scale)
	if _panel != null:
		_col.add_child(_panel)
		_col.move_child(_panel, 0)


func _target_h() -> float:
	return get_viewport_rect().size.y - 2.0 * MARGIN - HINT_BLOCK


# The factor that makes the panel span the screen height minus margins — capped by width so the
# panel never runs off the sides, by DESKTOP_MAX_SCALE on non-touch (see there), and never below
# the native 1.0 of the hover tooltip.
func _fit_scale() -> float:
	var vp := get_viewport_rect().size
	# Native panel: preview height / assembled width + the 12px content margins on both sides.
	var by_h := _target_h() / (CardTooltip.PREVIEW_SIZE.y + 24.0)
	var native_w := CardTooltip.PREVIEW_SIZE.x + 14.0 + CardTooltip.COLUMN_WIDTH + 24.0
	var by_w := (vp.x - 2.0 * MARGIN) / native_w
	var s := minf(by_h, by_w)
	if not DisplayServer.is_touchscreen_available():
		s = minf(s, DESKTOP_MAX_SCALE)
	return maxf(1.0, s)


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
	if is_press and not _dismissing:
		_dismissing = true
		visible = false
		get_viewport().set_input_as_handled()
	elif is_release and _dismissing:
		get_viewport().set_input_as_handled()
		if _layer != null:
			_layer.queue_free()
