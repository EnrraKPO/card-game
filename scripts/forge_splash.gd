class_name ForgeSplash
extends Node2D

# A one-shot outward burst of additive motes at this node's origin — the "splash" thrown off when
# two cards collide and fuse. Hand-drawn to match ForgeAura / ForgeLink (same additive dot look).
# Call burst() once; the node frees itself when every mote has faded.

var _motes: Array = []
var _t := 0.0
var _life := 0.6
var _color := Color.WHITE


# `count` motes fly out in all directions at speeds in [speed_min, speed_max] px/s, easing to a stop
# as they spread, and the whole burst fades over `life` seconds.
func burst(count: int, color: Color, speed_min: float, speed_max: float, size_min: float, size_max: float, life: float) -> void:
	_color = color
	_life = maxf(life, 0.01)

	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat

	_motes.clear()
	for i in count:
		var ang := randf() * TAU
		var spd := randf_range(speed_min, speed_max)
		_motes.append({
			"pos":   Vector2.ZERO,
			"vel":   Vector2(cos(ang), sin(ang)) * spd,
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
