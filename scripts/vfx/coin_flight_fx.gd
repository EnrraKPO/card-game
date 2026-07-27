class_name CoinFlightFx
extends RefCounted

# THE payment cue: one coin, per gold, flying off a dead unit and into the run's purse.
#
# A kill's bounty is a number the player would otherwise have to notice on a counter. Flying the
# coins makes the corpse the CAUSE and the bag the DESTINATION, so the transaction reads without
# a word — and paying one coin per gold makes the amount legible as a quantity of things rather
# than a digit that changed. A 4-cost body throws four coins; a 1-cost body throws one.
#
# Registered as the "coin_flight" library entry's custom renderer (Vfx.register_custom, from
# Combat), so every number below is authorable in data/vfx/vfx.json and the call site stays
#   Vfx.play("coin_flight", bag, {"origin": corpse_centre, "count": n, "on_land": cb})
#
# opts:
#   origin   Vector2  where the coins are thrown from, in global coordinates. A Vector2 and not
#                     a Control on purpose — the payer is a card that is being disposed of this
#                     very frame (see CombatBoard.remove_card), so the flight cannot hold it.
#   count    int      coins to throw (= gold paid).
#   on_land  Callable fired once per ARRIVING coin, so the bag's tally climbs with the coins
#                     rather than ahead of them (see GoldBag).
#
# ── ONE ARC, AND ONE KNOB ──────────────────────────────────────────────────────────
# Every coin of a payment rides the SAME curve, staggered in time — a stream down one path, not a
# spray. And the path itself obeys ONE rule, which is the whole design:
#
#   THE COIN NEVER MOVES AWAY FROM THE BAG. Not on x, not on y, not by a pixel.
#
# So the flight always lives inside the box the corpse and the bag span, and `curve` (0…1) is the
# single dial for how it crosses that box — as a circle arc, so both halves of the path are the
# same shape and the coin holds one speed the whole way (see _point):
#
#   0.0  the straight line, corner to corner
#   0.5  a gentle swing — the default
#   1.0  as round as the two points allow: a true quarter-circle when the horizontal and vertical
#        distances are equal, and flattening toward straight as they stop being
#
# Every earlier version bowed the path AROUND the straight line, which by definition overshoots
# something — and then needed caps and clamps to stop the overshoot leaving the screen or cresting
# past the bag. Those all fought a problem the shape invented. There is nothing to cap here: the
# rule above is a property of the formula at every value of the dial, not a limit imposed on it.
# Verify with dev/_coin_path.tscn, which walks the path and checks all four claims — monotone on
# both axes, equal deflection at the two ends, constant speed, and landing exactly on the bag.

const COIN_ART := "res://assets/ui/gold_coin.png"

# Fallbacks for every authorable param — the entry overrides any of them.
const DEF_SIZE := 34.0        # coin diameter in px
const DEF_DUR := 0.85         # one coin's flight along the lane
const DEF_STAGGER := 0.09     # gap between successive coins leaving the corpse
const DEF_CURVE := 0.3        # straight (0) … as round as the points allow (1) — THE dial (_point)
const DEF_SPREAD := 0.0       # dial variation between coins — 0, and see the note in play()
const SPIN := 1.25            # turns a coin makes on the way over


static func play(vd: VFXData, target: Control, opts: Dictionary) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	var count: int = int(opts.get("count", 0))
	if count <= 0:
		return
	var origin: Vector2 = opts.get("origin", Vector2.ZERO)
	var on_land: Callable = opts.get("on_land", Callable())
	var layer := Vfx.overlay_layer_for(target)

	var size: float = vd.num_param("size", DEF_SIZE)
	var dur: float = maxf(0.1, vd.num_param("duration", DEF_DUR))
	var stagger: float = maxf(0.0, vd.num_param("stagger", DEF_STAGGER))
	var curve: float = clampf(vd.num_param("curve", DEF_CURVE), 0.0, 1.0)
	var spread: float = vd.num_param("spread", DEF_SPREAD)
	var tex: Texture2D = load(COIN_ART) if ResourceLoader.exists(COIN_ART) else null

	var tree := target.get_tree()
	for i in count:
		if i > 0 and stagger > 0.0:
			await tree.create_timer(stagger).timeout
		if not is_instance_valid(target) or not target.is_inside_tree():
			return   # combat left while the purse was still filling
		# `spread` nudges the DIAL per coin, never the path in pixels (an offset would push a coin
		# outside the box and break the one rule). It defaults to 0, and that is the setting to
		# leave it at: the coins are already separated in TIME by `stagger`, so they can never
		# overlap, and giving each one its own dial value is what stops the payment reading as a
		# stream down one curve. Five coins on five slightly different arcs read as a fan of
		# crossing diagonals — the exact thing the header promises this cue is not.
		var rank := float((i + 1) / 2) * (1.0 if i % 2 == 1 else -1.0)
		_throw(layer, tex, origin, target, size, dur,
				clampf(curve + rank * spread, 0.0, 1.0), on_land)
	# The cue's own beat is the FIRST coin's arrival: the rest of the stream is still in the air
	# when combat moves on, which is the point — payment shouldn't stall the fight.
	await tree.create_timer(minf(dur, Vfx.paced(dur))).timeout


# One coin, launched now and cleaning up after itself. Not awaited by the loop above, so the
# whole stream is in the air at once.
static func _throw(layer: CanvasLayer, tex: Texture2D, origin: Vector2, target: Control,
		size: float, dur: float, curve: float, on_land: Callable) -> void:
	var coin := _make_coin(tex, size)
	layer.add_child(coin)
	# `position`, NEVER `global_position` — see the tween below for why it matters.
	coin.position = origin - coin.size * 0.5

	# The bag is read PER FRAME (the strip can relayout mid-flight), and every coin uses the same
	# formula, so they all ride the same curve — `curve` only varies its roundness a little so two
	# coins never sit exactly on top of each other.
	#
	# Timing is LINEAR on purpose. The curve already decides how the coin's speed splits between
	# the two axes; easing the parameter on top of that eases BOTH axes at once, which is what made
	# the old flight crawl into the bag at the end. Motion is the path's job, not the clock's.
	# ── `position`, NOT `global_position`. THE COIN SPINS, AND THAT IS WHY. ───────────
	#
	# A rotated Control's rect centre and its `global_position` are NOT one offset apart. The
	# transform is  position + pivot + R·S·(q − pivot),  so the rect centre sits at
	# `position + pivot`, while `global_position` reports the transform ORIGIN, at
	# `position + pivot − R·S·pivot`. Assigning global_position therefore pins the ORIGIN to the
	# path and leaves the visible coin at
	#
	#     centre = point + (R(θ) − I)·pivot
	#
	# — and θ here sweeps 1.25 full turns over the flight, so the coin ORBITS the path in a circle
	# of up to 2·|pivot| ≈ 48px, more than the arc's own bulge. That is what "the coins don't
	# follow the curve" was: a wobble larger than the curve, riding on a path that was correct all
	# along. Setting `position` puts the RECT where the maths wants it, and the centre lands on the
	# path for any rotation and any scale — including the arrival shrink, which pivots about the
	# same point. (The coin's parent is the overlay CanvasLayer, so position IS layer-global here.)
	var tw := layer.create_tween()
	tw.tween_method(func(t: float) -> void:
			if not is_instance_valid(coin):
				return
			coin.position = _point(origin, _bag_point(target, origin), curve, t) \
					- coin.size * 0.5
			coin.rotation = t * TAU * SPIN,
		0.0, 1.0, Vfx.paced(dur))
	tw.tween_callback(func() -> void:
		if on_land.is_valid():
			on_land.call()
		if is_instance_valid(coin):
			_pop_out(coin))


# The aim point: the bag's own declared drop point when it has one, its centre otherwise.
static func _bag_point(target: Control, fallback: Vector2) -> Vector2:
	if not is_instance_valid(target) or not target.is_inside_tree():
		return fallback
	if target.has_method("drop_point"):
		return target.call("drop_point")
	return target.get_global_rect().get_center()


# THE PATH: a CIRCLE ARC from the corpse to the bag, and `curve` is how much of one.
#
# Every property the flight needs is a property a circle already has, which is the reason to use
# one rather than blend easings or bow a line:
#
#   SYMMETRIC   both halves are the same shape mirrored — the arc bends AWAY from the straight
#               line by exactly as much as it bends back into it (±`turn`/2 at each end). An
#               easing blend or a bowed line is only symmetric when the two points happen to sit
#               on a square; stretch that box and the path leaves steeply and arrives flat.
#   SMOOTH      constant curvature, so there is no point along it that bends harder than any
#               other — and walking it at a constant ANGLE is walking it at a constant SPEED,
#               free. A curve made of eased axes speeds up as it goes, however it is paced.
#   EXACT       it is defined through both points, so it starts on the corpse and lands on the
#               bag, at every setting, with nothing to correct at the ends.
#
# `curve` is the fraction of the arc the geometry allows: 0 = the straight line, 1 = the roundest
# arc that still never turns back on either axis. That ceiling is the whole of THE ONE RULE, and
# it is a single angle. An arc's heading swings `turn`/2 to either side of the chord, so it stays
# monotone on both axes exactly while that swing keeps the heading inside the chord's own
# quadrant — i.e. while
#
#     turn <= 2 × (the chord's angle to the nearer axis)
#
# which is the ceiling below. It says the useful thing directly: a flight along a diagonal can be
# a full quarter-circle (the "1:1 round" end — a square box at curve 1.0 turns exactly 90°), and
# one that is nearly level can barely bend at all, because bending it would carry the coin back
# past the bag on the axis it has almost finished. A dead-level flight is dead straight, by
# design and by arithmetic both.
#
# The arc bows through the corner the coin would reach by climbing FIRST, so the coin lobs up out
# of the corpse and settles into the bag. Flip `bulge` to swing the other way round.
static func _point(from_p: Vector2, to_p: Vector2, curve: float, t: float) -> Vector2:
	var chord := to_p - from_p
	var span := chord.length()
	# How far the chord leans from the nearer of the two axes — the arc's whole allowance.
	var lean := atan2(absf(chord.y), absf(chord.x))
	var turn := clampf(curve, 0.0, 1.0) * 2.0 * minf(lean, PI * 0.5 - lean)
	if span < 0.001 or turn < 0.0001:
		return from_p.lerp(to_p, t)   # straight, and no radius to divide by
	# The centre sits off the chord's midpoint, on the far side from the bulge.
	var bulge := chord.orthogonal().normalized()
	var corner := Vector2(from_p.x, to_p.y)   # reached by climbing first — see above
	if bulge.dot(corner - from_p) < 0.0:
		bulge = -bulge
	var radius := span / (2.0 * sin(turn * 0.5))
	var centre := from_p.lerp(to_p, 0.5) - bulge * radius * cos(turn * 0.5)
	# Swept as a signed angle between the two radii, so t=0 and t=1 land ON the endpoints.
	var arm := from_p - centre
	return centre + arm.rotated(arm.angle_to(to_p - centre) * t)


static func _make_coin(tex: Texture2D, size: float) -> Control:
	var c: Control
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		c = tr
	else:
		# No art yet — a plain gold disc still reads as a coin at this size.
		var p := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1.0, 0.82, 0.28)
		sb.set_corner_radius_all(int(size * 0.5))
		sb.border_color = Color(0.55, 0.36, 0.06)
		sb.set_border_width_all(2)
		sb.anti_aliasing = true
		p.add_theme_stylebox_override("panel", sb)
		c = p
	c.custom_minimum_size = Vector2(size, size)
	c.size = Vector2(size, size)
	c.pivot_offset = c.size * 0.5
	c.z_index = 45
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# The coin disappears INTO the bag rather than at it: a quick shrink and fade at the drop point,
# under the bag's own thump, so the two halves of the arrival are one motion.
static func _pop_out(coin: Control) -> void:
	var tw := coin.create_tween()
	tw.set_parallel(true)
	tw.tween_property(coin, "scale", Vector2(0.35, 0.35), 0.14).set_ease(Tween.EASE_IN)
	tw.tween_property(coin, "modulate:a", 0.0, 0.14)
	tw.chain().tween_callback(coin.queue_free)
