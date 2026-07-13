class_name RelicInspector
extends Control

# Full-screen, tap-to-dismiss relic detail overlay — the touch answer to the relic chips'
# desktop hover tooltip (hover doesn't exist on touch). Opened by TAPPING a relic chip, the
# same rule on every screen (combat's strip, the map HUD). Where discarding is allowed (the
# map) the overlay carries the Discard button — replacing the old tap→confirm-dialog flow, so
# a stray tap can never start a discard. Modeled on CardInspector: scrim + centred panel, any
# press outside the Discard button closes it. Built in code (no scene), like the rest of the UI.

# Pinned width for the wrapped description (see CardTooltip's SIZING RULE — an unpinned
# autowrap label reports phantom minimum heights and balloons its panel).
const DESC_WIDTH := 620.0

var _relic: RelicData
var _can_discard: bool
var _on_discard: Callable
var _layer: CanvasLayer
var _dismissing := false
var _discard_btn: Button = null


# Opens the overlay above everything else. `host` only supplies the viewport (the overlay
# parents there so it stays inside whatever viewport the game runs in). `on_discard` runs when
# the Discard button (shown only with `can_discard`) is pressed; the overlay closes itself.
static func open(host: Node, relic: RelicData, can_discard := false,
		on_discard := Callable()) -> void:
	if relic == null or host == null or not host.is_inside_tree():
		return
	var insp := RelicInspector.new()
	insp._relic = relic
	insp._can_discard = can_discard
	insp._on_discard = on_discard
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

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	# The detail panel — CardTooltip's dark palette, with phone-first type sizes throughout.
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CardTooltip.BG_COLOR
	style.set_border_width_all(1)
	style.border_color = CardTooltip.BORDER_COLOR
	style.set_corner_radius_all(10)
	style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", style)
	col.add_child(panel)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 16)
	panel.add_child(inner)

	# The relic's look, big: its illustration when it has one, else its coloured-letter chip.
	if _relic.icon != null:
		var tex := TextureRect.new()
		tex.texture = _relic.icon
		tex.custom_minimum_size = Vector2(160, 160)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		inner.add_child(tex)
	else:
		var chip := Label.new()
		chip.text = _relic.letter
		chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chip.custom_minimum_size = Vector2(120, 120)
		chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		chip.add_theme_font_size_override("font_size", 64)
		chip.add_theme_color_override("font_color", Color(0.06, 0.06, 0.08))
		var chip_bg := StyleBoxFlat.new()
		chip_bg.bg_color = _relic.color
		chip_bg.set_corner_radius_all(18)
		chip_bg.set_border_width_all(3)
		chip_bg.border_color = Color(0.04, 0.04, 0.06, 0.9)
		var chip_panel := PanelContainer.new()
		chip_panel.add_theme_stylebox_override("panel", chip_bg)
		chip_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		chip_panel.add_child(chip)
		inner.add_child(chip_panel)

	var name_lbl := Label.new()
	name_lbl.text = _relic.display_name
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 40)
	name_lbl.add_theme_color_override("font_color", CardTooltip.TEXT_TITLE)
	inner.add_child(name_lbl)

	var desc := Label.new()
	desc.text = _relic.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc.custom_minimum_size.x = DESC_WIDTH
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", 30)
	desc.add_theme_color_override("font_color", CardTooltip.TEXT_MAIN)
	inner.add_child(desc)

	if _can_discard:
		_discard_btn = ScreenUI.action_button("Discard this relic", _do_discard,
			Vector2(320, 72), 24, ScreenUI.CHROME_DANGER)
		_discard_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		inner.add_child(_discard_btn)

	var hint := Label.new()
	hint.text = "Tap anywhere to close" if DisplayServer.is_touchscreen_available() \
			else "Click anywhere to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	col.add_child(hint)


func _do_discard() -> void:
	if _on_discard.is_valid():
		_on_discard.call()
	if _layer != null:
		_layer.queue_free()


# Any press anywhere dismisses — except on the Discard button, whose press belongs to the
# button. Same press/release consumption dance as CardInspector: the closing click is eaten
# whole so its release can't leak into whatever sits underneath.
func _input(event: InputEvent) -> void:
	var pos := Vector2.ZERO
	if event is InputEventMouseButton:
		pos = (event as InputEventMouseButton).position
	elif event is InputEventScreenTouch:
		pos = (event as InputEventScreenTouch).position
	else:
		return
	if _discard_btn != null and not _dismissing \
			and _discard_btn.get_global_rect().has_point(pos):
		return
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
