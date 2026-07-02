class_name CardInspector
extends Control

# Full-screen, tap-to-dismiss card detail overlay for touch. Hover tooltips don't exist on a
# touchscreen (a finger can't hover-and-wait), so a long-press on any CardUI opens this instead:
# the same shared CardTooltip panel, enlarged and centred over a dimmed scrim. Any press anywhere
# closes it. Built in code (no scene), mirroring the rest of the UI. See CardUI._gui_input.

var _inst: CardInstance
var _show_cost: bool
var _layer: CanvasLayer
var _dismissing := false


# Opens the inspector for `inst` above everything else (combat HUD, menus). `host` only supplies
# the scene tree; the overlay parents to the tree root so it survives the originating card.
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
	host.get_tree().root.add_child(layer)


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

	var panel := CardTooltip.build(_inst, _show_cost)
	if panel != null:
		col.add_child(panel)

	var hint := Label.new()
	hint.text = "Tap anywhere to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	col.add_child(hint)


# Any press anywhere dismisses. _input runs ahead of GUI routing, so this fires even when the tap
# lands on the card panel's own labels. Release events are ignored so the long-press that opened
# the inspector (the finger is still down at open time) doesn't immediately close it again.
func _input(event: InputEvent) -> void:
	var is_press := (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
	if is_press and not _dismissing:
		_dismissing = true
		get_viewport().set_input_as_handled()
		if _layer != null:
			_layer.queue_free()
