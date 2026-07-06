class_name AutocastFX
extends Control

# The autocast visual bundle shared by the AbilityWidget's brackets and the board echo on an
# armed holder: the four corner brackets, plus — only while ARMED — an additive glow copy of
# the brackets pulsing on top and golden sparkles orbiting the card edge corner to corner.
# Disarmed shows the plain brackets and nothing else (no dimming — armed-vs-not reads from
# the effects, not from an alpha treatment).
#
# Lives full-rect under a CardUI's fixed-size Canvas, so everything here is authored in
# native card units and scales with the card (see CardUI.build_autocast_fx).

const CORNERS := {
	"left_top":     preload("res://assets/ui/cards/autocast_corner_left_top.png"),
	"right_top":    preload("res://assets/ui/cards/autocast_corner_right_top.png"),
	"left_bottom":  preload("res://assets/ui/cards/autocast_corner_left_bottom.png"),
	"right_bottom": preload("res://assets/ui/cards/autocast_corner_right_bottom.png"),
}

const SPARKLE_COUNT := 11
const SPARKLE_COLOR := Color(1.0, 0.93, 0.5)
const SPARKLE_SPEED_MIN := 0.08   # perimeter fractions per second
const SPARKLE_SPEED_MAX := 0.16
const SPARKLE_TWINKLE_HZ := 6.0
# How far in from the frame edge the sparkle orbit runs (native units).
const EDGE_INSET := 10.0

var _armed := false
var _frame_size := Vector2.ZERO
var _glow_layer: Control = null
var _glow_tween: Tween = null
var _sparkles: Array = []   # dicts: t (perimeter position 0..1), speed, phase, size
var _time := 0.0


# `bracket_size`/`inset` place the corner art; `frame_size` is the native Canvas size the
# brackets frame (the sparkle orbit follows its edge). Call after adding to the tree.
func setup(bracket_size: Vector2, inset: float, frame_size: Vector2) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame_size = frame_size
	var positions := {
		"left_top":     Vector2(inset, inset),
		"right_top":    Vector2(frame_size.x - inset - bracket_size.x, inset),
		"left_bottom":  Vector2(inset, frame_size.y - inset - bracket_size.y),
		"right_bottom": Vector2(frame_size.x - inset - bracket_size.x,
				frame_size.y - inset - bracket_size.y),
	}
	for corner: String in CORNERS:
		add_child(_bracket_rect(corner, positions[corner] as Vector2, bracket_size))

	# The glow: an additive copy of the brackets on its own layer, alpha-pulsed while armed.
	# Additive blending over the bright yellow art is what reads as "shine".
	_glow_layer = Control.new()
	_glow_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow_layer.visible = false
	add_child(_glow_layer)
	_glow_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var glow_mat := CanvasItemMaterial.new()
	glow_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	for corner: String in CORNERS:
		var tr := _bracket_rect(corner, positions[corner] as Vector2, bracket_size)
		tr.material = glow_mat
		_glow_layer.add_child(tr)

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for _i in SPARKLE_COUNT:
		_sparkles.append({
			"t":     rng.randf(),
			"speed": rng.randf_range(SPARKLE_SPEED_MIN, SPARKLE_SPEED_MAX),
			"phase": rng.randf() * TAU,
			"size":  rng.randf_range(5.0, 9.0),
		})
	set_process(false)   # idle until armed (setup runs post-entry, so this sticks)


func _bracket_rect(corner: String, pos: Vector2, bracket_size: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = CORNERS[corner] as Texture2D
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.position = pos
	tr.size = bracket_size
	return tr


# Turns the armed effects (glow pulse + orbiting sparkles) on or off. Idempotent — refresh
# passes call this every board refresh, and the pulse must not restart each time.
func set_armed(armed: bool) -> void:
	if armed == _armed:
		return
	_armed = armed
	set_process(armed)
	_glow_layer.visible = armed
	if _glow_tween != null:
		_glow_tween.kill()
		_glow_tween = null
	if armed:
		_glow_layer.modulate.a = 0.9
		_glow_tween = create_tween()
		_glow_tween.set_loops()
		_glow_tween.tween_property(_glow_layer, "modulate:a", 0.2, 0.7).set_ease(Tween.EASE_IN_OUT)
		_glow_tween.tween_property(_glow_layer, "modulate:a", 0.9, 0.7).set_ease(Tween.EASE_IN_OUT)
	queue_redraw()   # disarming erases the sparkles immediately


func _process(delta: float) -> void:
	if not _armed:
		return
	_time += delta
	for s: Dictionary in _sparkles:
		s["t"] = fposmod(s["t"] as float + (s["speed"] as float) * delta, 1.0)
	queue_redraw()


func _draw() -> void:
	if not _armed:
		return
	for s: Dictionary in _sparkles:
		var center := _perimeter_point(s["t"] as float)
		# Each sparkle twinkles on its own phase; size breathes with the same wave.
		var tw := 0.55 + 0.45 * sin(_time * SPARKLE_TWINKLE_HZ + (s["phase"] as float))
		var size := (s["size"] as float) * (0.7 + 0.3 * tw)
		_draw_star(center, size, tw)


# A four-point star: an 8-vertex polygon (long spikes, pinched waist) plus a bright core.
func _draw_star(center: Vector2, s: float, alpha: float) -> void:
	var waist := s * 0.28
	var pts := PackedVector2Array([
		center + Vector2(0, -s),     center + Vector2(waist, -waist),
		center + Vector2(s, 0),      center + Vector2(waist, waist),
		center + Vector2(0, s),      center + Vector2(-waist, waist),
		center + Vector2(-s, 0),     center + Vector2(-waist, -waist),
	])
	draw_colored_polygon(pts, Color(SPARKLE_COLOR, alpha * 0.85))
	draw_circle(center, s * 0.24, Color(1.0, 1.0, 0.9, alpha))


# The point a perimeter fraction t (0..1, clockwise from the top-left) maps to on the orbit
# rectangle — the frame edge inset by EDGE_INSET, so sparkles ride the card border.
func _perimeter_point(t: float) -> Vector2:
	var origin := Vector2(EDGE_INSET, EDGE_INSET)
	var rect := _frame_size - Vector2(EDGE_INSET * 2.0, EDGE_INSET * 2.0)
	var d := t * 2.0 * (rect.x + rect.y)
	if d < rect.x:
		return origin + Vector2(d, 0)
	d -= rect.x
	if d < rect.y:
		return origin + Vector2(rect.x, d)
	d -= rect.y
	if d < rect.x:
		return origin + Vector2(rect.x - d, rect.y)
	d -= rect.x
	return origin + Vector2(0, rect.y - d)
