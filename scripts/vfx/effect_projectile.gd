class_name VFXEffectProjectile
extends VFXEffect

# A shot that flies from a source card to a target. Two looks (VFXEvent.Projectile):
#   ORB  — a round glowing ball, straight line; magic/triggered direct damage (resolves
#          impact itself).
#   BOLT — a ranged unit auto-attack shot with simulated projectile physics: it travels a
#          gravity ARC (constant horizontal speed, parabolic vertical so it lobs up then
#          accelerates down), noses along its velocity, and leaves a fading TRAIL so the whole
#          trajectory is readable. The caller applies the shield-split damage, so show_impact
#          is false and we only burst.
# When show_impact is true the damage was already applied to the data; we defer the target's
# HP-bar snap to _on_arrival() so it drops exactly as the shot lands.

const ORB_TRAVEL := 0.22

# Bolt physics. Duration scales with distance (constant nominal speed), clamped so close and
# far shots both stay readable. Arc height is a fraction of the distance, also clamped.
const BOLT_SPEED := 1150.0      # px/sec nominal
const BOLT_MIN_DUR := 0.42
const BOLT_MAX_DUR := 0.72
const BOLT_ARC_FRAC := 0.24     # apex height as a fraction of travel distance
const BOLT_ARC_MIN := 55.0
const BOLT_ARC_MAX := 240.0
const TRAIL_STEP := 15.0        # px between trail puffs

var _last_trail := Vector2.ZERO


func play() -> void:
	var src := _event.source
	var dst := _event.target
	if src == null or not is_instance_valid(src) or dst == null or not is_instance_valid(dst):
		_on_arrival()  # nothing to fly between — just resolve on the target
		queue_free()
		return

	if _event.proj_style == VFXEvent.Projectile.BOLT:
		await _fly_bolt(_center(src), _center(dst))
	else:
		await _fly_orb(_center(src), _center(dst))

	_on_arrival()
	queue_free()


# Straight magic ball (effect/spell damage).
func _fly_orb(from: Vector2, to: Vector2) -> void:
	var orb := _make_orb(_event.color)
	_root.add_child(orb)
	orb.global_position = from - orb.size * 0.5
	var tw := _root.create_tween()
	tw.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(orb, "global_position", to - orb.size * 0.5, ORB_TRAVEL)
	await tw.finished
	orb.queue_free()


# Arcing physical bolt (ranged attack). t runs linearly over time → constant horizontal
# speed and a gravity-accelerated descent, like a real lob.
func _fly_bolt(from: Vector2, to: Vector2) -> void:
	var dist := from.distance_to(to)
	var dur := clampf(dist / BOLT_SPEED, BOLT_MIN_DUR, BOLT_MAX_DUR)
	var arc := clampf(dist * BOLT_ARC_FRAC, BOLT_ARC_MIN, BOLT_ARC_MAX)

	var bolt := _make_bolt(_event.color)
	_root.add_child(bolt)
	bolt.pivot_offset = bolt.size * 0.5
	_last_trail = from

	var tw := _root.create_tween()
	tw.tween_method(
		func(t: float) -> void: _step_bolt(bolt, from, to, arc, t),
		0.0, 1.0, dur)
	await tw.finished
	bolt.queue_free()


func _step_bolt(bolt: Panel, from: Vector2, to: Vector2, arc: float, t: float) -> void:
	if not is_instance_valid(bolt):
		return
	var pos := _arc_point(from, to, arc, t)
	bolt.global_position = pos - bolt.size * 0.5
	bolt.rotation = _arc_tangent(from, to, arc, t).angle()   # nose along the flight path
	if pos.distance_to(_last_trail) >= TRAIL_STEP:
		_spawn_trail(pos, _event.color)
		_last_trail = pos


# Projectile arc: straight-line lerp with a downward-opening parabola subtracted (apex up at
# t=0.5). y grows fastest near the end → the visible "accelerate into the target".
func _arc_point(from: Vector2, to: Vector2, arc: float, t: float) -> Vector2:
	var p := from.lerp(to, t)
	p.y -= 4.0 * arc * t * (1.0 - t)
	return p


func _arc_tangent(from: Vector2, to: Vector2, arc: float, t: float) -> Vector2:
	var v := Vector2(to.x - from.x, (to.y - from.y) - 4.0 * arc * (1.0 - 2.0 * t))
	return v if v.length() > 0.01 else (to - from)


func _on_arrival() -> void:
	var dst := _event.target
	if dst != null and is_instance_valid(dst):
		_burst(_center(dst), _event.color)
	if _event.show_impact:
		_flash(Color(2.0, 0.3, 0.3))
		_float_label("-%d" % _event.amount, Color(1.0, 0.3, 0.3), "health")
		if dst != null and is_instance_valid(dst):
			dst.refresh()


# ── Visuals ──────────────────────────────────────────────────────────────────────

func _center(card: CardUI) -> Vector2:
	return card.global_position + card.size * 0.5


# Round magic ball — warm glowing core for triggered/spell damage.
func _make_orb(color: Color) -> Panel:
	var orb := Panel.new()
	orb.custom_minimum_size = Vector2(18, 18)
	orb.size = Vector2(18, 18)
	orb.z_index = 40
	orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.95, 0.8)        # hot white-gold core
	sb.set_corner_radius_all(9)                # full circle
	sb.shadow_color = Color(color, 0.7)        # themed glow
	sb.shadow_size = 10
	sb.anti_aliasing = true
	orb.add_theme_stylebox_override("panel", sb)
	return orb


# Chunky glowing capsule oriented along flight — a fired bolt/arrow for ranged attacks.
# Bigger + brighter than before so it reads the whole way across.
func _make_bolt(color: Color) -> Panel:
	var bolt := Panel.new()
	bolt.custom_minimum_size = Vector2(42, 13)
	bolt.size = Vector2(42, 13)
	bolt.z_index = 40
	bolt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = color.lightened(0.55)        # bright tinted core (reads on light + dark)
	sb.set_corner_radius_all(6)                # capsule ends
	sb.border_color = Color(1, 1, 1, 0.9)
	sb.set_border_width_all(2)
	sb.shadow_color = Color(color, 0.85)       # strong themed glow halo
	sb.shadow_size = 14
	sb.anti_aliasing = true
	bolt.add_theme_stylebox_override("panel", sb)
	return bolt


# Fading puff dropped along the bolt's path so the trajectory stays readable.
func _spawn_trail(pos: Vector2, color: Color) -> void:
	if _root == null:
		return
	var d := 12.0
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(d, d)
	dot.size = Vector2(d, d)
	dot.z_index = 38
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.pivot_offset = dot.size * 0.5
	dot.global_position = pos - dot.size * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color, 0.65)
	sb.set_corner_radius_all(int(d))
	sb.anti_aliasing = true
	dot.add_theme_stylebox_override("panel", sb)
	_root.add_child(dot)
	var tw := _root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(dot, "modulate:a", 0.0, 0.30)
	tw.tween_property(dot, "scale", Vector2(0.35, 0.35), 0.30)
	tw.chain().tween_callback(dot.queue_free)


# Expanding ring at the impact point — the satisfying "hit".
func _burst(center: Vector2, color: Color) -> void:
	if _root == null:
		return
	var d := 18.0
	var ring := Panel.new()
	ring.custom_minimum_size = Vector2(d, d)
	ring.size = Vector2(d, d)
	ring.z_index = 39
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.pivot_offset = ring.size * 0.5
	ring.global_position = center - ring.size * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color, 0.0)
	sb.set_corner_radius_all(int(d * 0.5))
	sb.border_color = Color(color, 0.9)
	sb.set_border_width_all(3)
	sb.anti_aliasing = true
	ring.add_theme_stylebox_override("panel", sb)
	_root.add_child(ring)
	var tw := _root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(2.4, 2.4), 0.28).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "modulate:a", 0.0, 0.28)
	tw.chain().tween_callback(ring.queue_free)
