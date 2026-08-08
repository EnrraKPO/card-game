extends Node
# Diagnostic for the kill-bounty coin flight: stages a real kill and logs EVERY coin's global
# position on EVERY frame, so the actual path can be read as numbers instead of guessed at from
# a blurred screenshot. Prints one line per frame: t, then each live coin's centre.
#
#   godot --path . res://dev/_coin_path.tscn

const OUT := "res://dev/_render_out.png"


func _ready() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()

	var sv := SubViewport.new()
	sv.size = Vector2i(1920, 1080)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.auto_start = false
	sv.add_child(shell)
	shell.mount("res://scenes/combat.tscn")
	await get_tree().process_frame

	var combat: Node = null
	for n: Node in sv.find_children("*", "Node", true, false):
		if n.has_method("get_chrome") and n.get("_board") != null:
			combat = n
			break
	var board = combat.get("_board")
	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			sv.add_child(vc)

	var victim := CardInstance.from_data(CardData.get_card("queen"))   # 5 cost = 5 coins
	board.place_enemy_card(victim, BoardLocation.at(1, 1, 1))
	await get_tree().process_frame
	var bag = combat.get("_gold_bag")
	print("BAG drop_point=", bag.drop_point())
	print("CORPSE centre=", board.get_card_ui(victim).get_global_rect().get_center())
	Resolver.set_health(victim, 0)
	combat.call("_bury", victim)

	# THE ONE RULE, asserted rather than eyeballed (see CoinFlightFx): walk the path at a fixed
	# step, at every setting of the dial, and check that neither axis EVER moves away from the bag
	# — that both endpoints are hit exactly — and report how far the path swings off the straight
	# line, so "0 = straight, 1 = fully round" is a measurement and not a claim.
	var from_p: Vector2 = board.get_card_ui(victim).get_global_rect().get_center()
	var to_p: Vector2 = bag.drop_point()
	for step in 6:
		_check(from_p, to_p, float(step) / 5.0, "real kill")
	# The two shapes the rule pins down: a level flight cannot bend at all, and a square box is
	# where the dial's top end means a literal quarter-circle.
	_check(from_p, Vector2(to_p.x, from_p.y), 1.0, "level (dy=0)")
	_check(Vector2(to_p.x + 1136.0, to_p.y + 1136.0), to_p, 1.0, "square box")

	# ── The FLIGHT, not the formula ──────────────────────────────────────────────────
	# The path checks out on paper, so watch what the coins actually do. Two things are logged
	# per frame that the formula can't see: where the bag says to aim RIGHT NOW (the flight
	# re-solves against it every frame, so if it moves the whole arc moves), and the heading of
	# the oldest coin in the air. A constant-curvature arc turns by the same amount every frame;
	# a frame that turns much harder than its neighbours is the kink, and the aim column beside
	# it says whether the target moved that frame.
	var last_aim: Vector2 = bag.drop_point()
	var prev_pos := Vector2.ZERO
	var prev_dir := Vector2.ZERO
	var trail: Array[Vector2] = []
	var t := 0.0
	for frame in 130:
		await get_tree().process_frame
		t += get_process_delta_time()
		var aim: Vector2 = bag.drop_point()
		var coins: Array[Vector2] = []
		for band: Node in sv.find_children("*", "CanvasLayer", true, false):
			for fx: Node in band.get_children():
				var c := fx as Control
				if c == null or not (c is TextureRect):
					continue
				coins.append(c.get_global_rect().get_center())
		if coins.is_empty():
			continue
		var lead: Vector2 = coins[0]
		trail.append(lead)
		var turn := 0.0
		if prev_pos != Vector2.ZERO:
			var dir := lead - prev_pos
			if dir.length() > 0.01:
				if prev_dir != Vector2.ZERO:
					turn = rad_to_deg(absf(prev_dir.angle_to(dir.normalized())))
				prev_dir = dir.normalized()
		prev_pos = lead
		print("t=%.3f  aim=(%.1f,%.1f)%s  lead=(%.0f,%.0f)  turn=%5.2f%s  coins=%d" % [
				t, aim.x, aim.y, "  <-- AIM MOVED" if aim.distance_to(last_aim) > 0.05 else "",
				lead.x, lead.y, turn, "  <-- KINK" if turn > 3.0 else "", coins.size()])
		last_aim = aim

	# A picture beats the columns: plot every sampled position of the lead coin, so the shape of
	# the flight can be LOOKED at. The ideal arc is drawn under it in a second colour — where the
	# two disagree is where the flight stops matching the formula.
	_plot(trail, from_p, to_p, "res://dev/_coin_trail.png")
	get_tree().quit()


const DIAL: Array[float] = [0.15, 0.3, 0.5, 0.75, 1.0]
const DIAL_COLOR: Array[Color] = [
	Color(0.40, 0.85, 0.45), Color(0.35, 0.75, 0.95), Color(1.00, 0.82, 0.28),
	Color(0.95, 0.55, 0.30), Color(0.95, 0.35, 0.45)]


func _plot(trail: Array[Vector2], from_p: Vector2, to_p: Vector2, path: String) -> void:
	var img := Image.create(1400, 560, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.06, 0.06, 0.09))
	# Cropped to the flight and squared up, so the shape is judged at a size the eye can read
	# instead of as a thread across an empty 1920x1080.
	var box := Rect2(from_p, Vector2.ZERO).expand(to_p).grow(90.0)
	var fit := minf(1340.0 / box.size.x, 500.0 / box.size.y)
	var at := func(p: Vector2) -> Vector2:
		return (p - box.position) * fit + Vector2(30, 30)
	# The straight chord, faint — the reference every curve is judged against.
	for i in 3001:
		_dot(img, at.call(from_p.lerp(to_p, float(i) / 3000.0)), 1, Color(0.30, 0.30, 0.36))
	# Every setting of the dial at once, so the choice is a look and not a description.
	for d in DIAL.size():
		for i in 3001:
			_dot(img, at.call(CoinFlightFx._point(from_p, to_p, DIAL[d], float(i) / 3000.0)),
					1, DIAL_COLOR[d])
	# What the coins ACTUALLY did, one blob per rendered frame — proof the flight rides the
	# formula rather than something the formula only describes.
	for p: Vector2 in trail:
		_dot(img, at.call(p), 4, Color(1, 1, 1, 0.9))
	_dot(img, at.call(from_p), 8, Color(0.9, 0.3, 0.3))
	_dot(img, at.call(to_p), 8, Color(0.4, 1.0, 0.5))
	img.save_png(path)
	print("TRAIL png -> ", path, "  samples=", trail.size(), "  dial=", DIAL)


func _dot(img: Image, p: Vector2, r: int, c: Color) -> void:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := int(p.x) + dx
			var y := int(p.y) + dy
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				img.set_pixel(x, y, c)


# All four claims CoinFlightFx makes about the path, walked and measured at one dial setting:
# it never gives ground on either axis, both halves deflect from the chord by the same angle
# (that is the symmetry), the speed never varies, and it finishes ON the bag.
func _check(from_p: Vector2, to_p: Vector2, k: float, label: String) -> void:
	var away := 0
	var swing := 0.0
	var fastest := 0.0
	var slowest := 1.0e9
	var prev := CoinFlightFx._point(from_p, to_p, k, 0.0)
	for i in range(1, 801):
		var p := CoinFlightFx._point(from_p, to_p, k, float(i) / 800.0)
		# "Closer on both axes" is direction-agnostic: compare the remaining gap.
		if absf(to_p.x - p.x) > absf(to_p.x - prev.x) + 0.0001 \
				or absf(to_p.y - p.y) > absf(to_p.y - prev.y) + 0.0001:
			away += 1
		swing = maxf(swing, _line_dist(from_p, to_p, p))
		var hop := p.distance_to(prev)
		fastest = maxf(fastest, hop)
		slowest = minf(slowest, hop)
		prev = p
	var chord := rad_to_deg((to_p - from_p).angle())
	var lead := rad_to_deg((CoinFlightFx._point(from_p, to_p, k, 0.002) - from_p).angle()) - chord
	var tail := chord - rad_to_deg((to_p - CoinFlightFx._point(from_p, to_p, k, 0.998)).angle())
	print("%-13s curve=%.1f  away=%d  swing=%3.0fpx  deflect start%+6.2f end%+6.2f  speed_var=%.1f%%  lands=%s" % [
			label, k, away, swing, lead, tail, (fastest / maxf(0.0001, slowest) - 1.0) * 100.0,
			CoinFlightFx._point(from_p, to_p, k, 1.0).distance_to(to_p) < 0.01])


# Perpendicular distance from the straight line a→b to point p — how far the path swings off
# the diagonal, which is what the dial is actually turning up and down.
func _line_dist(a: Vector2, b: Vector2, p: Vector2) -> float:
	var ab := b - a
	if ab.length() < 0.001:
		return 0.0
	return absf(ab.cross(p - a)) / ab.length()
