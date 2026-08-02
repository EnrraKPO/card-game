class_name ForgeDragItem
extends Control

# A draggable item in the Forge (a deck card, or a charm chip). It only reports the START of a
# drag — the CombinationScreen owns the live drag session (follower, particles, hit-testing,
# resolve) so it can anchor a beam between the floating preview and the hovered target. Touch is
# covered by Godot's default emulate_mouse_from_touch, so we only watch the left mouse button.

signal grab(payload: Dictionary)

var payload: Dictionary = {}


# Wraps `content` (a CardUI or a charm chip) and tags it with `p` (e.g. {"kind":"card","idx":i}).
# A CardUI is left on MOUSE_FILTER_PASS so it still answers the pointer itself — its hover ring and
# its details panel are the same ones every other surface in the game shows — while the press falls
# through to us to start the drag. Charm chips have no read of their own, so they stay IGNORE and we
# host their plain text tooltip.
func setup(content: Control, p: Dictionary) -> void:
	payload = p
	mouse_filter = Control.MOUSE_FILTER_STOP
	content.mouse_filter = Control.MOUSE_FILTER_PASS if content is CardUI else Control.MOUSE_FILTER_IGNORE
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(content)
	# WE ANSWER THE PRESS FOR IT, so we are the one who can say the card is live. A CardUI decides
	# whether it wears the hover ring and opens its details from whether a press on it does anything
	# (CardUI._pickable), and here nothing is wired to the card: the press is ours and the drag
	# session is the screen's. Left unsaid, a card that drags, taps and inspects would read as inert.
	# Asked from the live tree rather than latched, so a card taken out of this shell (the merge
	# framing rebuilds faces in place) stops claiming it the moment it leaves.
	var card := content as CardUI
	if card != null:
		card.interactive_check = func(c: CardUI) -> bool: return c.get_parent() is ForgeDragItem


# Charm chips' hosted tooltips (see setup) render keyword icons like every other rules text.
#
# ⚠ NULL WHEN THERE IS NOTHING TO SAY. Godot picks the tooltip's owner by walking UP from the
# innermost control under the pointer until it finds text or hits a STOP — which is us, always,
# since the card we wrap passes its pointer events through. So this is asked on every card hover
# too, with an empty string, and a body built from one is a real panel containing nothing: a blank
# tooltip popping over cards that have no native tooltip at all. Only charm chips are given text
# (see CombinationScreen), and only they have a tooltip to host.
func _make_custom_tooltip(for_text: String) -> Object:
	if UIScale.is_touch() or for_text.strip_edges().is_empty():
		return null
	return TextIcons.tooltip_body(for_text)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			grab.emit(payload)
			accept_event()
