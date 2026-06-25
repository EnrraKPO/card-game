class_name MapNodeMedallion
extends Button

# A single map node, rendered as its full-color type icon (the icon IS the node — no backing
# disc). MapScreen builds one per node and centres it on the node's map coordinate. The
# clickable target is the icon's box; the type caption and optional reward badge hang below
# it (mouse-transparent), so they don't shrink the tap area or block neighbouring nodes.
#
# State is conveyed on the icon itself: full brightness for a reachable node, a soft glow for
# the current node, and dimming for visited/locked. (Earlier versions drew a coloured
# medallion behind a black-silhouette icon — but the node icons are self-contained colour art,
# so a backing disc was redundant and is gone.)

enum State { LOCKED, REACHABLE, CURRENT, VISITED }

const _GLOW_COLOR := Color(1.0, 0.92, 0.34)

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


# Only the current node draws anything itself: a soft radial glow behind its icon so the
# player can immediately spot where they're standing.
func _draw() -> void:
	if _state != State.CURRENT:
		return
	var d := minf(size.x, size.y)
	var c := Vector2(size.x * 0.5, d * 0.5)
	var r := d * 0.5
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
	# Brightness alone separates the states (modulate multiplies, so it darkens, never brightens).
	match _state:
		State.VISITED: icon.modulate = Color(0.55, 0.55, 0.60)
		State.LOCKED:  icon.modulate = Color(0.40, 0.40, 0.46)
		_:             icon.modulate = Color.WHITE
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
	match _state:
		State.LOCKED:  lbl.modulate = Color(0.5, 0.5, 0.55)
		State.VISITED: lbl.modulate = Color(0.6, 0.6, 0.64)
		_:             lbl.modulate = Color(0.92, 0.93, 0.98)
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
	lbl.modulate = color if _state != State.VISITED else color.darkened(0.5)
	add_child(lbl)
