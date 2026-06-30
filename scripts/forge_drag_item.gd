class_name ForgeDragItem
extends Control

# A draggable item in the Forge (a deck card, or a charm chip). It only reports the START of a
# drag — the CombinationScreen owns the live drag session (follower, particles, hit-testing,
# resolve) so it can anchor a beam between the floating preview and the hovered target. Touch is
# covered by Godot's default emulate_mouse_from_touch, so we only watch the left mouse button.

signal grab(payload: Dictionary)

var payload: Dictionary = {}


# Wraps `content` (a CardUI or a charm chip) and tags it with `p` (e.g. {"kind":"card","idx":i}).
# A CardUI is left on MOUSE_FILTER_PASS so it shows its OWN standard hover tooltip (the same path
# the whole game uses) while still letting the press fall through to us to start the drag. Charm
# chips have no tooltip of their own, so they stay IGNORE and we host their plain text tooltip.
func setup(content: Control, p: Dictionary) -> void:
	payload = p
	mouse_filter = Control.MOUSE_FILTER_STOP
	content.mouse_filter = Control.MOUSE_FILTER_PASS if content is CardUI else Control.MOUSE_FILTER_IGNORE
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(content)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			grab.emit(payload)
			accept_event()
