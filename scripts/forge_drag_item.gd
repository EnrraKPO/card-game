class_name ForgeDragItem
extends Control

# A draggable item in the Forge (a deck card, or a charm chip). It only reports the START of a
# drag — the CombinationScreen owns the live drag session (follower, particles, hit-testing,
# resolve) so it can anchor a beam between the floating preview and the hovered target. Touch is
# covered by Godot's default emulate_mouse_from_touch, so we only watch the left mouse button.

signal grab(payload: Dictionary)

var payload: Dictionary = {}

# When set (card items), hover shows the shared rich CardTooltip instead of the plain text one.
# The inner CardUI is input-transparent, so the wrapper hosts the tooltip on its behalf.
var tooltip_card: CardInstance = null


# Wraps `content` (a CardUI or a charm chip) and tags it with `p` (e.g. {"kind":"card","idx":i}).
func setup(content: Control, p: Dictionary) -> void:
	payload = p
	mouse_filter = Control.MOUSE_FILTER_STOP
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(content)


# Card items get the full preview panel; charms (tooltip_card == null) fall back to tooltip_text.
func _make_custom_tooltip(_for_text: String) -> Object:
	if tooltip_card != null:
		return CardTooltip.build(tooltip_card)
	return null


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			grab.emit(payload)
			accept_event()
