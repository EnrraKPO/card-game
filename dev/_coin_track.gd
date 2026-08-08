extends Node
# One coin, tracked by identity, in numbers only — no screenshots, no colour thresholds, no
# blob finding. Every image-based diagnostic in this folder has measured the artwork instead of
# the coin at least once; this one cannot, because it never looks at a pixel.
#
# Per frame it prints, for the SAME node:
#   centre   the coin's own rect centre — where the code says the coin is
#   aim      what the bag reports as the drop point THIS FRAME (the flight re-reads it each frame)
#   off      how far `centre` is from the STATIC arc between the launch origin and the first
#            frame's aim, measured perpendicular
#
# That last column is the whole test, and it is not circular. The coin's position is assigned
# from _point, so if the inputs never change, `off` must be 0.0 forever. Any other number means
# an input moved mid-flight — and the aim column beside it says which.
#
#   godot --path D:\Godot\CardGame res://dev/_coin_track.tscn


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

	var victim := CardInstance.from_data(CardData.get_card("queen"))
	board.place_enemy_card(victim, BoardLocation.at(1, 1, 1))
	await get_tree().process_frame
	var bag = combat.get("_gold_bag")
	var origin: Vector2 = board.get_card_ui(victim).get_global_rect().get_center()
	var curve: float = VFXData.get_vfx("coin_flight").num_param("curve", CoinFlightFx.DEF_CURVE)
	print("ORIGIN=", origin, "  AIM0=", bag.drop_point(), "  curve=", curve)

	Vfx.play("coin_flight", bag, {"origin": origin, "count": 1})
	await get_tree().process_frame

	# Latch the one coin by identity and never look at any other node again.
	var coin: Control = null
	for band: Node in sv.find_children("*", "CanvasLayer", true, false):
		for fx: Node in band.get_children():
			if fx is TextureRect and coin == null:
				coin = fx as Control
	if coin == null:
		print("NO COIN FOUND")
		get_tree().quit()
		return

	var aim0: Vector2 = bag.drop_point()
	var worst := 0.0
	for frame in 120:
		await get_tree().process_frame
		if not is_instance_valid(coin):
			break
		# THE VISIBLE centre: `position + pivot_offset`, which is where a Control's rect actually
		# draws for ANY rotation or scale. get_global_rect() reports the transform ORIGIN instead,
		# which on a spinning node swings around the truth — measuring with it is what hid the
		# wobble (and what made the arrival shrink look like the coin flying off sideways).
		var centre: Vector2 = coin.position + coin.pivot_offset
		var aim: Vector2 = bag.drop_point()
		var off := _dist_to_arc(centre, origin, aim0, curve)
		worst = maxf(worst, off)
		# Everything about the node, so "what moved it" stops being a guess: its raw position and
		# size (centre is derived from both), its scale, and its identity.
		print("f=%3d id=%d  centre=(%7.1f,%7.1f)  pos=(%7.1f,%7.1f)  size=%s  scale=(%.2f,%.2f)  aim=(%6.1f,%6.1f)%s  off=%6.2f" % [
				frame, coin.get_instance_id(), centre.x, centre.y,
				coin.position.x, coin.position.y, coin.size, coin.scale.x, coin.scale.y,
				aim.x, aim.y, "  <-- AIM MOVED" if aim.distance_to(aim0) > 0.01 else "", off])
	print("WORST off_static_arc = %.2f px" % worst)
	get_tree().quit()


# Perpendicular distance from p to the arc _point() draws between a and b.
func _dist_to_arc(p: Vector2, a: Vector2, b: Vector2, curve: float) -> float:
	# 200 samples, not 2000: this runs per frame, and at 2000 it cost more than a frame — which
	# let the tween race ahead between samples and made the flight look 17 frames long.
	var best := 1.0e9
	for i in 201:
		best = minf(best, p.distance_to(CoinFlightFx._point(a, b, curve, float(i) / 200.0)))
	return best
