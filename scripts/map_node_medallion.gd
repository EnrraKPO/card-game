class_name MapNodeMedallion
extends Button

# A single map node, rendered as its full-color type icon over a light backing disc. MapScreen
# builds one per node and centres it on the node's map coordinate. The clickable target is the
# icon's box; the type caption and optional reward badge hang below it on a translucent dark
# plate (mouse-transparent), so they don't shrink the tap area or block neighbouring nodes, and
# stay legible where a trail's breadcrumb dots pass directly behind the text.
#
# State is conveyed by HIGHLIGHTING what's actionable, not by dimming what isn't — a locked or
# already-visited node still reads as a normal, fully-lit token (nothing on the map should look
# "broken" or disabled). Four DISTINCT treatments: REACHABLE gets a pulsing gold halo + thick
# double ring ("you can go here" — the only one that invites a click); CURRENT gets a steady
# (non-pulsing) cool-blue beacon ring ("you are standing here" — no longer actionable, so it must
# NOT read like an available node — kept to just the ring/halo, no extra marker glyph, since a
# floating dot above the node reads as clutter, especially tangled up with the trail dots);
# VISITED gets a green check badge ("done"); LOCKED gets only the plain neutral ring. The backing
# disc (see _draw) exists because the node icons are dark, low-saturation line art — against the
# app's map background they read as flat and dim without something to separate them from the
# page; the disc gives every icon the same contrast regardless of the background hue.
#
# All text and ring/badge geometry scales off `diameter`, so the medallion looks the same at any
# zoom level and on compact (which just passes a bigger diameter).

enum State { LOCKED, REACHABLE, CURRENT, VISITED }

const _HIGHLIGHT_RING := Color("f6b91e")   # CHROME_CONFIRM gold — "you can go here"
const _NEUTRAL_RING := Color("9c7622")
const _DONE_GREEN := Color(0.16, 0.55, 0.25)
const _CURRENT_COLOR := Color("5fd0e8")    # cool cyan — "you are here", deliberately not gold

var _state: int = State.LOCKED
var _diameter := 60.0
var _pulse_t := 0.0


# `caption` overrides the default type label (used for "Final Boss"); empty falls back to
# MapNodeData.get_label. `reward_summary` empty hides the reward badge.
func configure(node_type: MapNodeData.Type, state: int, diameter: float,
		caption: String, reward_summary: String, reward_color: Color) -> void:
	_state = state
	_diameter = diameter
	custom_minimum_size = Vector2(diameter, diameter)
	size = Vector2(diameter, diameter)
	flat = true
	disabled = state == State.LOCKED or state == State.VISITED
	# Drop the default button chrome so only the icon (and our state decoration) shows.
	for slot in ["normal", "hover", "pressed", "disabled", "focus"]:
		add_theme_stylebox_override(slot, StyleBoxEmpty.new())

	_build_icon(node_type)
	if state == State.VISITED:
		var overlay := Control.new()
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.draw.connect(_draw_check.bind(overlay))
		add_child(overlay)
	_build_text_plate(diameter, not reward_summary.is_empty())
	_build_caption(node_type, caption, diameter)
	if not reward_summary.is_empty():
		_build_reward(reward_summary, reward_color, diameter)

	# Only the actionable (reachable) node pulses — "where can I go" should stand out. The
	# current node gets a steady beacon instead: pulsing it would read as "click me" too.
	set_process(state == State.REACHABLE)
	queue_redraw()


func _process(delta: float) -> void:
	_pulse_t += delta
	queue_redraw()


# A light backing disc (so the dark icon art pops against the map bg), same for every state —
# plus a per-state ring treatment: REACHABLE gets a pulsing gold halo + thick double ring,
# CURRENT gets a steady cool-cyan ring (deliberately not gold, not pulsing — see class comment),
# LOCKED/VISITED get only the plain neutral ring; they're not darkened, just not singled out.
func _draw() -> void:
	var d := minf(size.x, size.y)
	var c := Vector2(size.x * 0.5, d * 0.5)
	var r := d * 0.5
	var disc_col := Color("f5ecd6")
	var reachable := _state == State.REACHABLE
	var is_current := _state == State.CURRENT
	var pulse := 0.7 + 0.3 * sin(_pulse_t * 3.4)

	if reachable:
		# Layered translucent gold halo, wide enough to read from across the map, pulsing to
		# draw the eye — this is the one state that invites a tap.
		for i in 4:
			var t := float(i) / 4.0
			var a := (0.07 + 0.06 * float(i)) * pulse
			draw_circle(c, r * (1.4 - t * 0.38), Color(_HIGHLIGHT_RING.r, _HIGHLIGHT_RING.g, _HIGHLIGHT_RING.b, a), true, -1.0, true)
	elif is_current:
		# Steady (non-pulsing) cyan halo — a calm "you are here" beacon, not an invitation.
		for i in 3:
			var t := float(i) / 3.0
			draw_circle(c, r * (1.3 - t * 0.28), Color(_CURRENT_COLOR.r, _CURRENT_COLOR.g, _CURRENT_COLOR.b, 0.16), true, -1.0, true)

	draw_circle(c, r * 0.94, disc_col)
	var ring_col := _NEUTRAL_RING
	var ring_w := d * 0.025
	if reachable:
		ring_col = _HIGHLIGHT_RING
		ring_w = d * 0.055
	elif is_current:
		ring_col = _CURRENT_COLOR
		ring_w = d * 0.055
	draw_arc(c, r * 0.94, 0.0, TAU, 64, ring_col, ring_w, true)
	if reachable:
		# Thin inner accent ring — the double ring reads as a "target" even in a still frame.
		var inner := Color(_HIGHLIGHT_RING.r, _HIGHLIGHT_RING.g, _HIGHLIGHT_RING.b, 0.85)
		draw_arc(c, r * 0.80, 0.0, TAU, 64, inner, maxf(1.5, d * 0.018), true)
	# The visited check badge is NOT drawn here: _draw renders under child controls, so the
	# icon art would cover it. configure adds a top overlay child that draws it instead.


# Green "done" badge with a white check, top-right of the disc. Drawn onto `overlay`
# (a child stacked above the icon) via its draw signal.
func _draw_check(overlay: Control) -> void:
	var d := minf(size.x, size.y)
	var c := Vector2(size.x * 0.5, d * 0.5)
	var r := d * 0.5
	var bc := c + Vector2(r * 0.72, -r * 0.72)
	var br := r * 0.34
	overlay.draw_circle(bc, br, _DONE_GREEN, true, -1.0, true)
	overlay.draw_arc(bc, br, 0.0, TAU, 32, Color(0.96, 0.99, 0.92), maxf(1.5, br * 0.16), true)
	var pts := PackedVector2Array([
		bc + Vector2(-br * 0.42, 0.02 * br),
		bc + Vector2(-br * 0.10, br * 0.36),
		bc + Vector2(br * 0.48, -br * 0.32),
	])
	overlay.draw_polyline(pts, Color(0.97, 1.0, 0.95), maxf(2.0, br * 0.26), true)


# A translucent dark rounded plate behind the caption (+ reward line, if any), so the text
# stays legible where a trail's breadcrumb dots pass directly behind it — without a backing
# panel the label glyphs and the dots visually merge. Drawn onto `overlay` (a child stacked
# below the text labels but above the node icon) via its draw signal.
func _draw_text_plate(overlay: Control, diameter: float, has_reward: bool) -> void:
	var cx := diameter * 0.5
	var top := diameter + diameter * 0.02
	var block_h := diameter * 0.30 + (diameter * 0.28 if has_reward else diameter * 0.08)
	var w := diameter * 1.9
	var rect := Rect2(Vector2(cx - w * 0.5, top), Vector2(w, block_h))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.11, 0.6)
	sb.set_corner_radius_all(int(diameter * 0.14))
	overlay.draw_style_box(sb, rect)


func _build_text_plate(diameter: float, has_reward: bool) -> void:
	var plate := Control.new()
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.draw.connect(_draw_text_plate.bind(plate, diameter, has_reward))
	add_child(plate)


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


func _build_caption(node_type: MapNodeData.Type, caption: String, diameter: float) -> void:
	var lbl := Label.new()
	lbl.text = caption if not caption.is_empty() else MapNodeData.get_label(node_type)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	lbl.add_theme_font_size_override("font_size", maxi(13, int(diameter * 0.22)))
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 0.9))
	lbl.add_theme_constant_override("outline_size", maxi(4, int(diameter * 0.075)))
	var w := diameter * 2.2
	lbl.size = Vector2(w, 0)
	lbl.position = Vector2(diameter * 0.5 - w * 0.5, diameter + diameter * 0.05)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var caption_col := Color(0.95, 0.96, 1.0)
	if _state == State.REACHABLE:
		caption_col = _HIGHLIGHT_RING
	elif _state == State.CURRENT:
		caption_col = _CURRENT_COLOR
	lbl.add_theme_color_override("font_color", caption_col)
	add_child(lbl)


func _build_reward(summary: String, color: Color, diameter: float) -> void:
	var lbl := Label.new()
	lbl.text = summary
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", maxi(11, int(diameter * 0.17)))
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 0.9))
	lbl.add_theme_constant_override("outline_size", maxi(3, int(diameter * 0.06)))
	var w := diameter * 2.2
	var caption_h := diameter * 0.3
	lbl.size = Vector2(w, 0)
	lbl.position = Vector2(diameter * 0.5 - w * 0.5, diameter + diameter * 0.05 + caption_h)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Tint via font_color (not modulate) so the dark outline stays dark and the text stays
	# readable; lift very dark element colors toward white so they read on the map background.
	var col := color
	if col.get_luminance() < 0.45:
		col = col.lerp(Color(0.95, 0.95, 1.0), 0.5)
	lbl.add_theme_color_override("font_color", col)
	add_child(lbl)
