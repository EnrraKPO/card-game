class_name MapNodeMedallion
extends Button

# A single map node, rendered as its full-color type icon over a light backing disc. MapScreen
# builds one per node and centres it on the node's map coordinate. The clickable target is the
# icon's box; the type caption and optional reward badge hang below it (mouse-transparent), so
# they don't shrink the tap area or block neighbouring nodes.
#
# State is conveyed by HIGHLIGHTING what's actionable, not by dimming what isn't — a locked or
# already-visited node still reads as a normal, fully-lit token (nothing on the map should look
# "broken" or disabled); a reachable node gets a bright accent ring, and the current node additionally
# gets its pulsing glow. The backing disc (see _draw) exists because the node icons are dark,
# low-saturation line art — against the app's light/warm ochre map background they read as flat
# and dim without something to separate them from the page; the disc gives every icon the same
# contrast regardless of the map's background hue.

enum State { LOCKED, REACHABLE, CURRENT, VISITED }

const _GLOW_COLOR := Color(1.0, 0.92, 0.34)
const _HIGHLIGHT_RING := Color("f6b91e")   # CHROME_CONFIRM gold — "you can go here"
const _NEUTRAL_RING := Color("9c7622")

var _state: int = State.LOCKED
var _diameter := 60.0


# `caption` overrides the default type label (used for "Final Boss"); empty falls back to
# MapNodeData.get_label. `reward_summary` empty hides the reward badge.
func configure(node_type: MapNodeData.Type, state: int, diameter: float, compact: bool,
		caption: String, reward_summary: String, reward_color: Color) -> void:
	_state = state
	_diameter = diameter
	custom_minimum_size = Vector2(diameter, diameter)
	size = Vector2(diameter, diameter)
	flat = true
	disabled = state == State.LOCKED or state == State.VISITED
	# Drop the default button chrome so only the icon (and our current-node glow) shows.
	for slot in ["normal", "hover", "pressed", "disabled", "focus"]:
		add_theme_stylebox_override(slot, StyleBoxEmpty.new())

	_build_icon(node_type)
	_build_caption(node_type, caption, compact, diameter)
	if not reward_summary.is_empty():
		_build_reward(reward_summary, reward_color, compact, diameter)

	queue_redraw()


# A light backing disc (so the dark icon art pops against the map bg), same for every state —
# plus a highlight ring for a reachable node and, on top of that, a soft pulsing-style glow for
# wherever the player currently stands. Locked/visited nodes get only the plain neutral ring;
# they're not darkened, just not singled out.
func _draw() -> void:
	var d := minf(size.x, size.y)
	var c := Vector2(size.x * 0.5, d * 0.5)
	var r := d * 0.5
	var disc_col := Color("f5ecd6")
	var highlighted := _state == State.REACHABLE or _state == State.CURRENT
	var ring_col := _HIGHLIGHT_RING if highlighted else _NEUTRAL_RING
	var ring_w := 3.5 if highlighted else 2.0
	draw_circle(c, r * 0.94, disc_col)
	draw_arc(c, r * 0.94, 0.0, TAU, 48, ring_col, ring_w, true)
	if highlighted:
		draw_circle(c, r * 1.1, Color(_HIGHLIGHT_RING.r, _HIGHLIGHT_RING.g, _HIGHLIGHT_RING.b, 0.14), true, -1.0, true)
	if _state != State.CURRENT:
		return
	for i in 3:
		var t := float(i) / 3.0
		draw_circle(c, r * (1.18 - t * 0.14), Color(_GLOW_COLOR.r, _GLOW_COLOR.g, _GLOW_COLOR.b, 0.16), true, -1.0, true)


func _build_icon(node_type: MapNodeData.Type) -> void:
	var tex := MapNodeData.get_icon(node_type)
	if tex == null:
		return
	var icon := TextureRect.new()
	# Set expand/stretch BEFORE size: while expand_mode is the default KEEP_SIZE, the
	# TextureRect's minimum size equals the full texture resolution, which would clamp our
	# size UP to the texture's pixel size (the icon would render huge). IGNORE_SIZE drops the
	# minimum to zero so the explicit full-node size below is honoured.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2.ZERO
	icon.texture = tex
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Full brightness regardless of state — see the class comment: locked/visited read as normal,
	# not "disabled." State is conveyed by the highlight ring in _draw instead.
	add_child(icon)


func _build_caption(node_type: MapNodeData.Type, caption: String, compact: bool, diameter: float) -> void:
	var lbl := Label.new()
	lbl.text = caption if not caption.is_empty() else MapNodeData.get_label(node_type)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	lbl.add_theme_font_size_override("font_size", 30 if compact else 12)
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 0.9))
	lbl.add_theme_constant_override("outline_size", 5 if compact else 3)
	var w := diameter * 2.0
	lbl.size = Vector2(w, 0)
	lbl.position = Vector2(diameter * 0.5 - w * 0.5, diameter + (6.0 if compact else 2.0))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var highlighted := _state == State.REACHABLE or _state == State.CURRENT
	lbl.add_theme_color_override("font_color", _HIGHLIGHT_RING if highlighted else Color(0.92, 0.93, 0.98))
	add_child(lbl)


func _build_reward(summary: String, color: Color, compact: bool, diameter: float) -> void:
	var lbl := Label.new()
	lbl.text = summary
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 26 if compact else 11)
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 0.9))
	lbl.add_theme_constant_override("outline_size", 4 if compact else 2)
	var w := diameter * 2.0
	var caption_h := (40.0 if compact else 16.0)
	lbl.size = Vector2(w, 0)
	lbl.position = Vector2(diameter * 0.5 - w * 0.5, diameter + (6.0 if compact else 2.0) + caption_h)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.modulate = color
	add_child(lbl)
