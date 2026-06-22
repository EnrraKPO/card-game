class_name ForgeLink
extends Node2D

# The connection between two cards: motes stream from each card and converge to a point on the
# other — a vortex / attraction funnel pulling particles across. Hand-drawn (additive crisp dots)
# so the funnel can taper and swirl, which particle nodes can't do. Endpoints are set every frame
# by the screen; `setup` seeds the motes once. ALL tuning lives in ForgeFX.LINK.

var from := Vector2.ZERO
var to := Vector2.ZERO
var color := Color.WHITE

var _t := 0.0
var _motes: Array = []

# Cached from ForgeFX.LINK at setup (keeps the per-frame draw typed and cheap).
var _width_factor := 0.5
var _width_min := 12.0
var _width_max := 160.0
var _converge_pow := 1.0
var _alpha_base := 0.85
var _alpha_amp := 0.15
var _alpha_min := 0.55
var _alpha_max := 1.0


func setup(p_color: Color) -> void:
	color = p_color

	var cfg := ForgeFX.LINK
	_width_factor = float(cfg["width_factor"])
	_width_min = float(cfg["width_min"])
	_width_max = float(cfg["width_max"])
	_converge_pow = float(cfg["converge_pow"])
	_alpha_base = float(cfg["alpha_base"])
	_alpha_amp = float(cfg["alpha_amp"])
	_alpha_min = float(cfg["alpha_min"])
	_alpha_max = float(cfg["alpha_max"])

	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat

	_motes.clear()
	for i in int(cfg["count"]):
		_motes.append({
			"dir":   0 if randf() < 0.5 else 1,    # 0 = from→to, 1 = to→from (a two-way vortex)
			"u":     randf(),                       # progress 0 (source) → 1 (sink), pre-populated
			"spd":   randf_range(float(cfg["speed_min"]), float(cfg["speed_max"])),
			"amp":   randf_range(float(cfg["amp_min"]), float(cfg["amp_max"])),
			"twist": randf_range(float(cfg["twist_min"]), float(cfg["twist_max"])),
			"phase": randf() * TAU,
			"size":  randf_range(float(cfg["size_min"]), float(cfg["size_max"])),
			"white": randf() < float(cfg["white_chance"]),
			"flick": randf_range(float(cfg["flick_min"]), float(cfg["flick_max"])),
		})


func set_endpoints(p_from: Vector2, p_to: Vector2) -> void:
	from = p_from
	to = p_to


func _process(delta: float) -> void:
	_t += delta
	for m in _motes:
		m["u"] = fposmod(float(m["u"]) + float(m["spd"]) * delta, 1.0)
	queue_redraw()


func _draw() -> void:
	var axis := to - from
	var dist := axis.length()
	if dist < 1.0:
		return
	var perp := Vector2(-axis.y, axis.x) / dist
	# Width scales with the gap (small minimum so close cards don't blow up into a perpendicular cross).
	var width_px := clampf(dist * _width_factor, _width_min, _width_max)
	for m in _motes:
		var u := float(m["u"])
		var src := from if int(m["dir"]) == 0 else to
		var dst := to if int(m["dir"]) == 0 else from
		var base := src.lerp(dst, u)
		# Wide at the source, swirling, converging to a point on the sink card = an attraction funnel.
		var swirl := sin(u * float(m["twist"]) * TAU + float(m["phase"]))
		var pos := base + perp * (width_px * float(m["amp"]) * pow(1.0 - u, _converge_pow) * swirl)
		var c: Color = Color.WHITE if bool(m["white"]) else color
		c.a = clampf(_alpha_base + _alpha_amp * sin(_t * 6.0 * float(m["flick"]) + float(m["phase"])), _alpha_min, _alpha_max)
		draw_circle(pos, float(m["size"]), c, true, -1.0, true)
