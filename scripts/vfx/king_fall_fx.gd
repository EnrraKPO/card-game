class_name KingFallFx
extends RefCounted

# The enemy King's end — the biggest single beat in a fight, and the only one the whole run has
# been building toward. It is deliberately NOT a death: a unit dissolves, a King goes critical.
#
# The shape is a TENSION BUILD, four phases, and the order is the whole point — each one has to
# read as "this is getting worse" before the release lands:
#
#   SWELL   the card grows, slowly, past its own size (to `grow`). Nothing else changes yet.
#   TREMBLE a vibration starts under the swell, so faint it registers before it is noticed, and
#           its amplitude climbs the whole way. Motes begin streaming outward, accelerating.
#   SPIKE   a short, hard escalation: the shake triples, the card pushes bigger and whites out,
#           the stream turns into a torrent. Brief on purpose — the moment before the drop.
#   BURST   release. The card is GONE in a couple of frames (scale to nothing under a white
#           flash) inside a radial shockwave and a spray of shards.
#
# Registered as the "king_fall" library entry's renderer, so every duration and rate below is a
# data question (data/vfx/vfx.json). ATOMIC by nature: Combat awaits this in full and then pops
# the reward chest out of the burst (see Combat._king_fall / TreasureChest.pop_from) — the chest
# is thrown by this explosion, so the explosion has to have finished happening.
#
# Everything here is paced through Vfx.paced: at Snappy the whole build compresses rather than
# playing at its authored length while the rest of combat runs quick around it.

const DEF_SWELL := 1.15      # seconds of grow-and-tremble
const DEF_SPIKE := 0.32      # seconds of hard escalation
const DEF_BURST := 0.14      # seconds for the card itself to be annihilated
const DEF_GROW := 1.2        # scale reached by the end of the swell
const DEF_SHAKE_MAX := 7.0   # px of tremble at the end of the swell…
const DEF_SPIKE_SHAKE := 22.0 # …and at the peak of the spike
const DEF_RATE_MIN := 6.0    # motes per second at the start of the swell…
const DEF_RATE_MAX := 130.0  # …and at the peak of the spike


static func play(vd: VFXData, target: Control, _opts: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	var color := vd.color_param("color", Color(1.0, 0.85, 0.35))
	var layer := Vfx.overlay_layer_for(target)
	var motes := _Motes.new()
	motes.target = target
	motes.color = color
	layer.add_child(motes)

	# The card is ours for the duration — claimed through the displacement lock so no other cue
	# fights us for its position, and released to its true rest if something outranks us.
	var rest := Vfx.begin_displace(target)
	Vfx.claim_reaction(target, 3.0)
	target.pivot_offset = target.size * 0.5

	var grow: float = vd.num_param("grow", DEF_GROW)
	var shake_max: float = vd.num_param("shake", DEF_SHAKE_MAX)
	var spike_shake: float = vd.num_param("spike_shake", DEF_SPIKE_SHAKE)
	var rate_min: float = vd.num_param("rate_min", DEF_RATE_MIN)
	var rate_max: float = vd.num_param("rate_max", DEF_RATE_MAX)

	# ── SWELL + TREMBLE ──
	var swell := Vfx.paced(maxf(0.1, vd.num_param("swell", DEF_SWELL)), vd)
	var t1 := target.create_tween()
	t1.tween_method(func(p: float) -> void:
			if not is_instance_valid(target):
				return
			# Growth eases; the tremble and the stream do NOT — both accelerate, so the build
			# reads as something losing control rather than something animating to a pose.
			var e: float = smoothstep(0.0, 1.0, p)
			target.scale = Vector2.ONE * lerpf(1.0, grow, e)
			var amp: float = lerpf(0.4, shake_max, p * p)
			target.position = rest + Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
			motes.rate = lerpf(rate_min, rate_max * 0.45, p * p)
			motes.speed = lerpf(60.0, 190.0, p),
		0.0, 1.0, swell)
	Vfx.hold_displace(target, t1)
	await t1.finished

	# ── SPIKE ──
	Sfx.play("spell_cast")   # the charge topping out, right before the release
	var spike := Vfx.paced(maxf(0.05, vd.num_param("spike", DEF_SPIKE)), vd)
	var t2 := target.create_tween()
	t2.tween_method(func(p: float) -> void:
			if not is_instance_valid(target):
				return
			target.scale = Vector2.ONE * lerpf(grow, grow + 0.1, p)
			var amp: float = lerpf(shake_max, spike_shake, p)
			target.position = rest + Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
			# Whiting out: the art burns away into the light it is about to become.
			target.modulate = Color(1, 1, 1).lerp(Color(3.0, 2.6, 1.8), p)
			motes.rate = lerpf(rate_max * 0.45, rate_max, p)
			motes.speed = lerpf(190.0, 330.0, p),
		0.0, 1.0, spike)
	Vfx.hold_displace(target, t2)
	await t2.finished

	# ── BURST ──
	Sfx.play("unit_death_large")
	var centre := target.get_global_rect().get_center()
	motes.rate = 0.0                      # the stream stops; the explosion takes over
	motes.burst(int(vd.num_param("shards", 34.0)), centre)
	layer.add_child(_shockwave(centre, color))
	layer.add_child(_flash(centre, color))
	var burst := Vfx.paced(maxf(0.05, vd.num_param("burst", DEF_BURST)), vd)
	var t3 := target.create_tween()
	t3.set_parallel(true)
	t3.tween_property(target, "scale", Vector2(0.05, 0.05), burst).set_ease(Tween.EASE_IN)
	t3.tween_property(target, "modulate:a", 0.0, burst)
	await t3.finished
	# The motes outlive the beat and fade on their own — the caller is free to carry on the
	# instant the card is gone, which is when the chest is thrown.
	motes.retire()


# The expanding ring the burst throws off — the shape that says "outward" faster than particles can.
static func _shockwave(centre: Vector2, color: Color) -> Control:
	var ring := _RingFx.new()
	ring.color = color
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.global_position = centre
	ring.z_index = 50
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "radius", 420.0, 0.5).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "width", 2.0, 0.5)
	tw.tween_property(ring, "modulate:a", 0.0, 0.5).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(ring.queue_free)
	return ring


# The white core of the detonation: a hot disc that blooms and dies in a breath.
static func _flash(centre: Vector2, color: Color) -> Control:
	var f := _DiscFx.new()
	f.color = Color(1, 1, 1)
	f.rim = color
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.global_position = centre
	f.z_index = 49
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	f.material = mat
	var tw := f.create_tween()
	tw.tween_property(f, "radius", 190.0, 0.10).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(f, "modulate:a", 1.0, 0.06)
	tw.tween_property(f, "radius", 250.0, 0.34)
	tw.parallel().tween_property(f, "modulate:a", 0.0, 0.34)
	tw.chain().tween_callback(f.queue_free)
	return f


# ── Draw nodes ─────────────────────────────────────────────────────────────────────

class _RingFx extends Control:
	var color := Color.WHITE
	var width := 10.0:
		set(v): width = v; queue_redraw()
	var radius := 10.0:
		set(v): radius = v; queue_redraw()
	func _draw() -> void:
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, color, width, true)


class _DiscFx extends Control:
	const LAYERS := 9   # a hard-edged white circle reads as a cheap sprite; the falloff is what
						 # makes it read as a detonation's light (same idea as Vfx's radiance)
	var color := Color.WHITE
	var rim := Color.WHITE
	var radius := 8.0:
		set(v): radius = v; queue_redraw()
	func _draw() -> void:
		for i in LAYERS:
			var f: float = 1.0 - float(i) / float(LAYERS - 1)   # 1 = outermost, drawn first
			draw_circle(Vector2.ZERO, radius * lerpf(0.25, 1.0, f),
					Color(rim.r, rim.g, rim.b, pow(1.0 - f, 2.0) * 0.5))
		draw_circle(Vector2.ZERO, radius * 0.22, Color(color.r, color.g, color.b, 0.95))


# The stream: motes leaving the King outward in every direction, at a rate and speed the build
# drives from outside. One node draws them all; it tracks the card while the card exists and
# keeps emitting from the last known centre once it doesn't.
class _Motes extends Control:
	var target: Control
	var color := Color(1.0, 0.85, 0.35)
	var rate := 0.0        # motes per second (the build ramps this)
	var speed := 90.0      # px/sec they leave at (likewise)
	var retiring := false

	var _parts: Array[Dictionary] = []
	var _accum := 0.0
	var _centre := Vector2.ZERO
	var _spawn_r := 60.0


	func _ready() -> void:
		z_index = 48
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = mat
		_sync()


	# Stops emitting and frees itself once the last mote has faded.
	func retire() -> void:
		retiring = true
		rate = 0.0


	# The detonation's own spray: a ring of fast shards thrown at once from `centre`.
	func burst(count: int, centre: Vector2) -> void:
		_centre = centre
		for i in count:
			var a := TAU * float(i) / float(maxi(1, count)) + randf() * 0.4
			_spawn(a, randf_range(420.0, 900.0), randf_range(0.45, 0.85), randf_range(3.0, 7.0))


	func _sync() -> void:
		if target != null and is_instance_valid(target) and target.is_inside_tree():
			var r := target.get_global_rect()
			_centre = r.get_center()
			_spawn_r = minf(r.size.x, r.size.y) * 0.42


	func _spawn(angle: float, spd: float, life: float, rad: float) -> void:
		_parts.append({
			"p": _centre + Vector2.RIGHT.rotated(angle) * randf_range(0.0, _spawn_r),
			"v": Vector2.RIGHT.rotated(angle) * spd,
			"age": 0.0, "life": life, "r": rad,
		})


	func _process(delta: float) -> void:
		_sync()
		if rate > 0.0:
			_accum += delta * rate
			while _accum >= 1.0:
				_accum -= 1.0
				# Outward in every direction, with a slight upward bias — light rises, and it
				# keeps the stream off the cards below.
				var a := randf() * TAU
				_spawn(a, speed * randf_range(0.6, 1.3), randf_range(0.5, 1.0),
						randf_range(2.0, 5.0))
		var alive: Array[Dictionary] = []
		for p: Dictionary in _parts:
			p["age"] = float(p["age"]) + delta
			p["p"] = Vector2(p["p"]) + Vector2(p["v"]) * delta
			p["v"] = Vector2(p["v"]) * (1.0 - minf(0.9, delta * 1.6))   # drag, so they drift out
			if float(p["age"]) < float(p["life"]):
				alive.append(p)
		_parts = alive
		if retiring and _parts.is_empty():
			queue_free()
			return
		queue_redraw()


	func _draw() -> void:
		for p: Dictionary in _parts:
			var t: float = clampf(float(p["age"]) / float(p["life"]), 0.0, 1.0)
			var a: float = (1.0 - t) * (1.0 - t)
			var r: float = float(p["r"]) * (1.0 - 0.4 * t)
			if a <= 0.01 or r <= 0.3:
				continue
			var local: Vector2 = Vector2(p["p"]) - global_position
			draw_circle(local, r, Color(color.r, color.g, color.b, a * 0.9))
			draw_circle(local, r * 0.45, Color(1, 1, 1, a * 0.8))
