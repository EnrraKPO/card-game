class_name RewardOrbFx
extends RefCounted

# The reward leaving the chest and becoming the next screen.
#
# An opened chest and a reward screen are the same event, and the game used to cut between them.
# This is the thing that carries one into the other: a bright orb gathers out of the open lid,
# rises, then flies to the CENTRE of the screen trailing sparks — and the screen the win leads
# to grows from that exact point (see ScreenGrowFx / Shell.mount's arrival cue). Nothing is
# navigated until the orb lands, so there is no cut anywhere in the chain.
#
#   Vfx.play("reward_orb", chest, {"on_arrive": func(): ...})
#
# Drawn on the VFX overlay rather than inside the screen that spawned it: combat is torn down a
# frame after `on_arrive` fires, and the orb has to still be hanging in the air, holding the
# spot, while the new screen swells out from under it.

const DEF_GATHER := 0.34    # the orb pulling itself together over the open lid
const DEF_RISE := 0.20      # a beat of hang before it goes
const DEF_FLIGHT := 0.62    # the trip to the middle of the screen
const DEF_LINGER := 0.34    # how long it holds the centre before dissolving into the new screen
const DEF_RADIUS := 34.0    # the orb at full size


static func play(vd: VFXData, target: Control, opts: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		# No chest to leave from — the handoff still has to happen, or combat waits forever.
		var cb_now: Callable = opts.get("on_arrive", Callable())
		if cb_now.is_valid():
			cb_now.call()
		return
	var on_arrive: Callable = opts.get("on_arrive", Callable())
	var layer := Vfx.overlay_layer_for(target)
	var color := vd.color_param("color", Color(1.0, 0.93, 0.62))
	var radius: float = vd.num_param("radius", DEF_RADIUS)

	var rect := target.get_global_rect()
	var from := Vector2(rect.get_center().x, rect.position.y + rect.size.y * 0.30)
	var to := target.get_viewport_rect().size * 0.5

	var orb := _Orb.new()
	orb.color = color
	orb.core = radius
	orb.at = from
	layer.add_child(orb)

	# GATHER — the light collects out of the chest before anything moves.
	var tw := orb.create_tween()
	tw.tween_method(func(p: float) -> void: orb.energy = p, 0.0, 1.0,
			Vfx.paced(vd.num_param("gather", DEF_GATHER))).set_trans(Tween.TRANS_SINE)
	tw.tween_property(orb, "at", from - Vector2(0, rect.size.y * 0.45),
			Vfx.paced(vd.num_param("rise", DEF_RISE))).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await tw.finished

	# FLIGHT — a gentle curve into the middle, not a straight slide: the orb sweeps up and over
	# so the eye follows it away from the board rather than across it.
	var lift := from.distance_to(to) * 0.16
	var mid := from.lerp(to, 0.5) - Vector2(0, lift)
	var start := orb.at
	var fly := orb.create_tween()
	fly.tween_method(func(t: float) -> void:
			orb.at = start.lerp(mid, t).lerp(mid.lerp(to, t), t)
			orb.trail = true,
		0.0, 1.0, Vfx.paced(vd.num_param("flight", DEF_FLIGHT))) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	fly.parallel().tween_method(func(s: float) -> void: orb.swell = s, 1.0, 1.45,
			Vfx.paced(vd.num_param("flight", DEF_FLIGHT)))
	await fly.finished

	Sfx.play("reward_open")
	orb.trail = false
	orb.flash()
	if on_arrive.is_valid():
		on_arrive.call()   # the screen starts growing from here, under the orb

	# LINGER — the orb dies INTO the arriving screen rather than before it, so the two overlap
	# and the handoff has no seam.
	var out := orb.create_tween()
	out.tween_method(func(p: float) -> void: orb.energy = p, 1.0, 0.0,
			Vfx.paced(vd.num_param("linger", DEF_LINGER))).set_trans(Tween.TRANS_SINE)
	out.tween_callback(orb.queue_free)


# The orb itself: a hot core in a soft halo, with a spark trail it drops while travelling and a
# ring it throws when it arrives. One node draws the lot, in viewport space.
class _Orb extends Control:
	const HALO_LAYERS := 8   # discs in the falloff stack (see _draw)

	var color := Color(1.0, 0.93, 0.62)
	var core := 34.0
	var energy := 0.0:          # 0 = not there yet, 1 = fully gathered
		set(v): energy = v; queue_redraw()
	var swell := 1.0:
		set(v): swell = v; queue_redraw()
	var at := Vector2.ZERO:
		set(v):
			if trail and v.distance_to(at) > 9.0:
				_sparks.append({"p": at, "age": 0.0, "r": randf_range(3.0, 8.0)})
			at = v
			queue_redraw()
	var trail := false

	var _sparks: Array[Dictionary] = []
	var _ring := 0.0
	var _ring_a := 0.0


	func _ready() -> void:
		z_index = 70   # above everything, including a screen growing underneath it
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = mat


	# The arrival punch: one ring thrown outward from where it stopped.
	func flash() -> void:
		_ring = core
		_ring_a = 0.9
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_method(func(v: float) -> void: _ring = v; queue_redraw(), core, core * 6.0, 0.45) \
				.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
		tw.tween_method(func(v: float) -> void: _ring_a = v; queue_redraw(), 0.9, 0.0, 0.45)


	func _process(delta: float) -> void:
		if _sparks.is_empty():
			return
		var alive: Array[Dictionary] = []
		for s: Dictionary in _sparks:
			s["age"] = float(s["age"]) + delta
			if float(s["age"]) < 0.42:
				alive.append(s)
		_sparks = alive
		queue_redraw()


	func _draw() -> void:
		for s: Dictionary in _sparks:
			var st: float = clampf(float(s["age"]) / 0.42, 0.0, 1.0)
			draw_circle(Vector2(s["p"]) - global_position, float(s["r"]) * (1.0 - st),
					Color(color.r, color.g, color.b, (1.0 - st) * 0.7 * energy))
		if _ring_a > 0.001:
			draw_arc(at - global_position, _ring, 0.0, TAU, 48,
					Color(color.r, color.g, color.b, _ring_a),
					maxf(2.0, 7.0 * _ring_a), true)
		if energy <= 0.001:
			return
		var c := at - global_position
		var r := core * swell * (0.35 + 0.65 * energy)
		# A stack of discs with a SQUARED alpha falloff, drawn outside-in. Three flat discs read
		# as a grey plate once the additive blend sits on a light background — the gradient is
		# what makes it read as light instead (the same falloff Vfx's radiance primitive uses).
		for i in HALO_LAYERS:
			var f: float = 1.0 - float(i) / float(HALO_LAYERS - 1)   # 1 = outermost
			draw_circle(c, r * lerpf(0.7, 2.4, f),
					Color(color.r, color.g, color.b, pow(1.0 - f, 2.0) * 0.55 * energy))
		draw_circle(c, r * 0.5, Color(1, 1, 1, 0.95 * energy))   # the hot core
