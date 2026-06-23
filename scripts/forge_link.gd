class_name ForgeLink
extends Node2D

# The connection between two cards: motes peel off one card's orbit RING, arc across the gap, and
# merge onto the other card's ring — fading in/out at each ring so it reads as a seamless transfer
# of particles from one orbit to the other (never diving through the card centre). Hand-drawn
# additive dots; endpoints + ring radii are set every frame by the screen. Tuning: ForgeFX.LINK.

var from := Vector2.ZERO   # source card centre
var to := Vector2.ZERO     # sink card centre
var rx := 60.0             # ring half-extents (both cards share a size)
var ry := 80.0
var color := Color.WHITE

var _t := 0.0
var _motes: Array = []

# Cached from ForgeFX.LINK at setup.
var _bow := 0.18
var _end_fade := 0.22
var _alpha_base := 0.85
var _alpha_amp := 0.15
var _alpha_min := 0.55
var _alpha_max := 1.0


func setup(p_color: Color) -> void:
	color = p_color
	var cfg := ForgeFX.LINK
	_bow = float(cfg["bow"])
	_end_fade = float(cfg["end_fade"])
	_alpha_base = float(cfg["alpha_base"])
	_alpha_amp = float(cfg["alpha_amp"])
	_alpha_min = float(cfg["alpha_min"])
	_alpha_max = float(cfg["alpha_max"])

	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat

	var spread := float(cfg["spread"])
	_motes.clear()
	for i in int(cfg["count"]):
		_motes.append({
			"dir":  0 if randf() < 0.5 else 1,    # 0 = from→to, 1 = to→from (two-way exchange)
			"u":    randf(),                        # progress 0 (source ring) → 1 (sink ring)
			"spd":  randf_range(float(cfg["speed_min"]), float(cfg["speed_max"])),
			"a0":   randf_range(-spread, spread),   # where on the source ring it leaves (vs facing pt)
			"a1":   randf_range(-spread, spread),   # where on the sink ring it arrives
			"bow":  randf_range(-1.0, 1.0),         # which way (and how much) its arc bends
			"size": randf_range(float(cfg["size_min"]), float(cfg["size_max"])),
			"white": randf() < float(cfg["white_chance"]),
			"flick": randf_range(float(cfg["flick_min"]), float(cfg["flick_max"])),
		})


func set_endpoints(p_from: Vector2, p_to: Vector2, p_rx: float, p_ry: float) -> void:
	from = p_from
	to = p_to
	rx = p_rx
	ry = p_ry


func _process(delta: float) -> void:
	_t += delta
	for m in _motes:
		m["u"] = fposmod(float(m["u"]) + float(m["spd"]) * delta, 1.0)
	queue_redraw()


# A point on an ellipse ring of half-extents rx/ry, centred at `c`, at angle `ang`.
func _ring(c: Vector2, ang: float) -> Vector2:
	return c + Vector2(rx * cos(ang), ry * sin(ang))


func _draw() -> void:
	var axis := to - from
	if axis.length() < 1.0:
		return
	var facing := atan2(axis.y, axis.x)   # from → to
	for m in _motes:
		var fwd := int(m["dir"]) == 0
		var src_c := from if fwd else to
		var dst_c := to if fwd else from
		# Each card's near side faces the other; the sink's facing point looks back (facing + PI).
		var p0 := _ring(src_c, (facing if fwd else facing + PI) + float(m["a0"]))
		var p1 := _ring(dst_c, (facing + PI if fwd else facing) + float(m["a1"]))

		var u := float(m["u"])
		var seg := p1 - p0
		var base := p0.lerp(p1, smoothstep(0.0, 1.0, u))
		var perp := Vector2(-seg.y, seg.x).normalized()
		var pos := base + perp * (seg.length() * _bow * float(m["bow"]) * sin(u * PI))

		# Fade in leaving the source ring, out arriving the sink ring → blends into the halos.
		var fade := clampf(minf(u, 1.0 - u) / _end_fade, 0.0, 1.0)
		var c: Color = Color.WHITE if bool(m["white"]) else color
		c.a = clampf(_alpha_base + _alpha_amp * sin(_t * 6.0 * float(m["flick"])), _alpha_min, _alpha_max) * fade
		draw_circle(pos, float(m["size"]), c, true, -1.0, true)
