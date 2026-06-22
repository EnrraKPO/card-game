class_name ForgeAura
extends Node2D

# A hand-drawn halo of motes that swirl around a card on a superellipse (card-shaped path, not a
# scaled circle). Each mote orbits at its own speed/direction and weaves in/out with layered sine
# wobble + flicker, so the ring reads as restless "magical tension" rather than a clean orbit.
# Lives as a child of the (moving) card so it follows it. ALL tuning lives in ForgeFX.AURA.

var rx := 6.0
var ry := 8.0
var color := Color.WHITE

var intensity := 1.0          # current swirl energy (motes spin/brighten faster as it rises)
var _target_intensity := 1.0  # eased toward, so connecting/disconnecting ramps smoothly

var _t := 0.0
var _motes: Array = []

# Cached from ForgeFX.AURA at setup (keeps the per-frame draw typed and cheap).
var _path_exp := 0.55
var _alpha_base := 0.85
var _alpha_amp := 0.15
var _alpha_min := 0.65
var _alpha_max := 1.0
var _ease := 8.0


func setup(p_rx: float, p_ry: float, p_color: Color) -> void:
	rx = p_rx
	ry = p_ry
	color = p_color
	_t = randf() * 10.0

	var cfg := ForgeFX.AURA
	_path_exp = float(cfg["path_exp"])
	_alpha_base = float(cfg["alpha_base"])
	_alpha_amp = float(cfg["alpha_amp"])
	_alpha_min = float(cfg["alpha_min"])
	_alpha_max = float(cfg["alpha_max"])
	_ease = float(cfg["intensity_ease"])

	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat

	var counter := float(cfg["counter_rotate"])
	_motes.clear()
	for i in int(cfg["count"]):
		var dir := -1.0 if randf() < counter else 1.0
		_motes.append({
			"ang":     randf() * TAU,
			"spd":     dir * randf_range(float(cfg["spin_min"]), float(cfg["spin_max"])),
			"r_amp":   randf_range(float(cfg["wobble_amp_min"]), float(cfg["wobble_amp_max"])),
			"r_freq":  randf_range(float(cfg["wobble_freq_min"]), float(cfg["wobble_freq_max"])),
			"r_phase": randf() * TAU,
			"a_amp":   randf_range(float(cfg["ang_jitter_min"]), float(cfg["ang_jitter_max"])),
			"a_freq":  randf_range(float(cfg["ang_freq_min"]), float(cfg["ang_freq_max"])),
			"a_phase": randf() * TAU,
			"size":    randf_range(float(cfg["size_min"]), float(cfg["size_max"])),
			"white":   randf() < float(cfg["white_chance"]),
			"flick":   randf_range(float(cfg["flick_min"]), float(cfg["flick_max"])),
		})


func set_intensity(v: float) -> void:
	_target_intensity = v


func _process(delta: float) -> void:
	intensity = lerpf(intensity, _target_intensity, clampf(delta * _ease, 0.0, 1.0))
	_t += delta
	for m in _motes:
		m["ang"] += float(m["spd"]) * delta * intensity
	queue_redraw()


func _draw() -> void:
	for m in _motes:
		var wob := 1.0 + float(m["r_amp"]) * sin(_t * float(m["r_freq"]) + float(m["r_phase"]))
		var a := float(m["ang"]) + float(m["a_amp"]) * sin(_t * float(m["a_freq"]) + float(m["a_phase"]))
		var pos := _path_point(a) * wob
		var c: Color = Color.WHITE if bool(m["white"]) else color
		c.a = clampf(_alpha_base + _alpha_amp * sin(_t * 6.0 * float(m["flick"]) + float(m["r_phase"])), _alpha_min, _alpha_max)
		draw_circle(pos, float(m["size"]), c, true, -1.0, true)   # filled, anti-aliased


# A point on the superellipse for angle `a`: flat-ish sides + rounded corners (a card-like path).
func _path_point(a: float) -> Vector2:
	var ca := cos(a)
	var sa := sin(a)
	return Vector2(rx * signf(ca) * pow(absf(ca), _path_exp), ry * signf(sa) * pow(absf(sa), _path_exp))
