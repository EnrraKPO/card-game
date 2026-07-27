extends Node
# What the coin flight ACTUALLY LOOKS LIKE. Not a plot of the formula, not sampled coordinates
# drawn as dots — the real rendered frames of a real payment, strobed into one image.
#
# Every earlier diagnostic here drew the path from the maths and scattered measured points over
# it, and every conclusion drawn from those pictures was wrong: the samples hopped between
# different coins, and the lines were the very thing under suspicion. This probe cannot make that
# mistake, because it never evaluates the path at all. It photographs the screen.
#
#   godot --path D:\Godot\CardGame res://dev/_coin_real.tscn     (needs a window, NOT --headless)
#
# Writes two images:
#   dev/_coin_real_one.png   ONE coin, alone. This is the picture that answers "is the path
#                            itself smooth" — nothing else is on screen to confuse it.
#   dev/_coin_real_all.png   a full 5-coin payment, exactly as a real kill throws it. This is
#                            the picture that answers "does the STREAM read as one curve".
#
# The strobe is a lighten (per-pixel max) of every captured frame, so a coin leaves its whole
# path behind at once — bright gold on a dark screen composites cleanly this way.

const OUT_ONE := "res://dev/_coin_real_one.png"
const OUT_ALL := "res://dev/_coin_real_all.png"
const FRAMES := 90        # ~1.5s at 60fps: a coin's whole flight plus its arrival
const SHRINK := 2         # capture at half size — still far more than the shape needs

var _sv: SubViewport


func _ready() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()

	_sv = SubViewport.new()
	_sv.size = Vector2i(1920, 1080)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.auto_start = false
	_sv.add_child(shell)
	shell.mount("res://scenes/combat.tscn")
	await get_tree().process_frame

	var combat: Node = null
	for n: Node in _sv.find_children("*", "Node", true, false):
		if n.has_method("get_chrome") and n.get("_board") != null:
			combat = n
			break
	var board = combat.get("_board")
	# The VFX overlay lives on the autoload, outside this viewport — it has to be moved in or the
	# coins render to the main window and the capture comes back empty. (This is also why the
	# COORDINATES a probe reads off a coin can't be trusted against the bag's; the picture, being
	# one composite of one render, is unaffected.)
	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			_sv.add_child(vc)

	var victim := CardInstance.from_data(CardData.get_card("queen"))   # 5 cost = 5 coins
	board.place_enemy_card(victim, 1, 1)
	await get_tree().process_frame
	var bag = combat.get("_gold_bag")
	var corpse: Vector2 = board.get_card_ui(victim).get_global_rect().get_center()
	var vd := VFXData.get_vfx("coin_flight")
	print("BAG=", bag.drop_point(), "  CORPSE=", corpse,
			"  curve=", vd.num_param("curve", CoinFlightFx.DEF_CURVE),
			"  spread=", vd.num_param("spread", CoinFlightFx.DEF_SPREAD))

	# Just the corridor the flight uses, so the shape fills the picture instead of being a thread
	# across a screenshot — and so 90 frames of it fit in memory at once.
	var corridor := Rect2(bag.drop_point(), Vector2.ZERO).expand(corpse).grow(110.0)
	var crop := Rect2i(corridor).intersection(Rect2i(Vector2i.ZERO, _sv.size))

	# The INTENDED path, drawn into the very canvas layer the coins fly on — so the picture
	# compares the two without me mapping anything between coordinate spaces. Every previous
	# comparison here went through my own arithmetic about crops and scales, and that arithmetic
	# is exactly what a capture is supposed to make unnecessary.
	var guide := _Guide.new()
	guide.from_p = corpse
	guide.to_p = bag.drop_point()
	guide.curve = vd.num_param("curve", CoinFlightFx.DEF_CURVE)
	Vfx.overlay_layer_for(bag).add_child(guide)

	# ── ONE coin, on its own ─────────────────────────────────────────────────────────
	Vfx.play("coin_flight", bag, {"origin": corpse, "count": 1})
	# The coin is drawn ~28px off the line the SAME function draws. Everything between computing
	# the point and drawing the sprite is printed here — the two nodes' layers, their rects, and
	# their with-canvas transforms — because one of them is not in the space the other is.
	await get_tree().process_frame
	await get_tree().process_frame
	for band: Node in _sv.find_children("*", "CanvasLayer", true, false):
		for fx: Node in band.get_children():
			if not (fx is TextureRect):
				continue
			var c := fx as Control
			print("COIN   layer=%s(%d)  size=%s  pos=%s  rect_centre=%s" % [
					band.name, (band as CanvasLayer).layer, c.size, c.global_position,
					c.get_global_rect().get_center()])
			print("COIN   xform=%s  with_canvas=%s" % [
					c.get_global_transform().origin, c.get_global_transform_with_canvas().origin])
			guide.coin = c
	print("GUIDE  layer=%s(%d)  xform=%s  with_canvas=%s" % [
			guide.get_parent().name, (guide.get_parent() as CanvasLayer).layer,
			guide.get_global_transform().origin, guide.get_global_transform_with_canvas().origin])
	# Both forms of the SAME point this time — the previous dump compared the icon's centre with
	# the VBox's corner and the difference between those two was nothing but the icon's inset.
	print("BAG    node_xform=%s  node_with_canvas=%s  (equal => one space)  drop=%s" % [
			bag.get_global_transform().origin, bag.get_global_transform_with_canvas().origin,
			bag.drop_point()])
	await _strobe(OUT_ONE, crop)

	# ── The whole payment, thrown by a real death down the real wire ─────────────────
	Resolver.set_health(victim, 0)
	combat.call("_bury", victim)
	await _strobe(OUT_ALL, crop)
	get_tree().quit()


# Lighten-composite FRAMES rendered frames into one image and save it.
#
# TWO PHASES, and the split is the whole point. Compositing in GDScript costs far longer than a
# frame, so doing it inside the capture loop lets real time run on between shots and the coin is
# photographed a handful of times across its whole flight — a picture with gaps in it, which
# cannot answer a question about smoothness. So the loop below does nothing but grab frames, and
# every pixel of work happens after the flight is over.
func _strobe(path: String, crop: Rect2i) -> void:
	# The loop does ONE thing per frame: read the texture and crop it (a memcpy). Anything more —
	# a resize, a pixel pass — costs longer than a frame and the capture starts skipping, which is
	# how the first two attempts came back with gaps in the trail and answered nothing.
	var shots: Array[Image] = []
	for i in FRAMES:
		await RenderingServer.frame_post_draw
		shots.append(_sv.get_texture().get_image().get_region(crop))
	var w := int(crop.size.x / SHRINK)
	var h := int(crop.size.y / SHRINK)
	var acc := Image.create(w, h, false, Image.FORMAT_RGBA8)
	acc.fill(Color.BLACK)
	for shot: Image in shots:
		shot.resize(w, h, Image.INTERPOLATE_BILINEAR)   # now that nothing is waiting on us
		for y in h:
			for x in w:
				var a := acc.get_pixel(x, y)
				var b := shot.get_pixel(x, y)
				# Per-channel max: whatever was brightest at this pixel in ANY frame. A moving
				# coin therefore paints its entire path, over a background that never moves.
				if b.r > a.r or b.g > a.g or b.b > a.b:
					acc.set_pixel(x, y, Color(maxf(a.r, b.r), maxf(a.g, b.g), maxf(a.b, b.b), 1.0))
	acc.save_png(path)
	print("STROBE -> ", path, "  (", w, "x", h, ", ", shots.size(), " frames)")


# The path CoinFlightFx says the coin will take, drawn as a line on the coins' own canvas layer.
# Cyan for the arc, white pips for the two endpoints it is defined by.
class _Guide extends Node2D:
	var from_p: Vector2
	var to_p: Vector2
	var curve: float
	var coin: Control    # the live coin, marked each frame in THIS node's own space

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var pts := PackedVector2Array()
		for i in 401:
			pts.append(CoinFlightFx._point(from_p, to_p, curve, float(i) / 400.0))
		draw_polyline(pts, Color(0.2, 1.0, 1.0), 3.0)
		draw_circle(from_p, 7.0, Color(1, 1, 1))
		draw_circle(to_p, 7.0, Color(1, 1, 1))
		# THE SELF-PROVING BIT: a magenta pip at where the coin says its centre is, drawn by a
		# different node, in a different node's coordinates. If the pip lands on the gold sprite,
		# the coin is drawn where it claims and both live in the same space — no analysis of mine
		# involved. If the pip and the sprite are apart, that gap IS the bug, in one picture.
		# `position + pivot_offset` — the rect's TRUE drawn centre for any rotation or scale.
		# get_global_rect() reports the transform origin, which on a spinning node swings around
		# the truth; marking with it was measuring the very bug under test.
		if coin != null and is_instance_valid(coin):
			draw_circle(coin.position + coin.pivot_offset, 4.0, Color(1.0, 0.2, 0.9))
