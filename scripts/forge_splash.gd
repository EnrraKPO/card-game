class_name ForgeSplash
extends Node2D

# A one-shot outward burst of additive motes at this node's origin — the "splash" thrown off when
# two cards collide and fuse. Hand-drawn to match ForgeAura / ForgeLink (same additive dot look).
# Call burst() once; the node frees itself when every mote has faded.

var _motes: Array = []
var _t := 0.0
var _life := 0.6
var _color := Color.WHITE


# The library face of this class: the renderer behind the `forge_contact_splash` entry
# (registered by the CombinationScreen — see Vfx.register_custom). Every knob reads from the
# entry's params, so the burst is tunable from the Tool like any other cue; the moment's element
# colour rides in via opts.color (the entry's own colour is only the fallback). The burst
# centres on `target`, spawns its motes on an ellipse of `origin` × the target's size (see
# burst's origin_radii), and draws on the target's overlay band — never clipped, depth-correct
# against modal scrims.
static func play_entry(vd: VFXData, target: Control, opts: Dictionary) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	var fx := ForgeSplash.new()
	Vfx.overlay_layer_for(target).add_child(fx)
	var rect := target.get_global_rect()
	fx.global_position = rect.get_center()
	var color := vd.color_param("color", Color.WHITE)
	if opts.get("color") is Color:
		color = opts.get("color")
	fx.burst(
			int(vd.num_param("count", 18.0)),
			color,
			vd.num_param("speed_min", 45.0),
			vd.num_param("speed_max", 165.0),
			vd.num_param("size_min", 2.0),
			vd.num_param("size_max", 4.5),
			vd.num_param("life", 1.0),
			rect.size * vd.num_param("origin", 0.0))


# `count` motes fly out in all directions at speeds in [speed_min, speed_max] px/s, easing to a stop
# as they spread, and the whole burst fades over `life` seconds.
# `origin_radii` spreads the SPAWN points onto an ellipse of those half-extents (with a little
# jitter), each mote flying outward along its own spawn angle — so a burst can begin at an
# object's boundary and visibly spill PAST it, instead of every mote starting buried at the
# centre where slow, gentle speeds never clear the object's own silhouette. ZERO = the classic
# single-point burst.
func burst(count: int, color: Color, speed_min: float, speed_max: float, size_min: float, size_max: float, life: float,
		origin_radii: Vector2 = Vector2.ZERO) -> void:
	_color = color
	_life = maxf(life, 0.01)

	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat

	_motes.clear()
	for i in count:
		var ang := randf() * TAU
		var dir := Vector2(cos(ang), sin(ang))
		var spd := randf_range(speed_min, speed_max)
		_motes.append({
			"pos":   dir * origin_radii * randf_range(0.9, 1.1),
			"vel":   dir * spd,
			"size":  randf_range(size_min, size_max),
			"white": randf() < 0.5,
		})


func _process(delta: float) -> void:
	if _motes.is_empty():
		return                              # burst() not called yet — don't tick or self-free
	_t += delta
	var damp := exp(-delta * 3.0)           # motes coast to a halt as they scatter
	for m in _motes:
		m["pos"] = Vector2(m["pos"]) + Vector2(m["vel"]) * delta
		m["vel"] = Vector2(m["vel"]) * damp
	queue_redraw()
	if _t >= _life:
		queue_free()


func _draw() -> void:
	var k := clampf(1.0 - _t / _life, 0.0, 1.0)   # global fade 1 → 0
	for m in _motes:
		var c: Color = Color.WHITE if bool(m["white"]) else _color
		c.a = k
		draw_circle(Vector2(m["pos"]), float(m["size"]) * (0.4 + 0.6 * k), c, true, -1.0, true)
