extends Node
# Does a PRACTICE fight (Combat Gym) pay its kill bounties? It used to not — _rewards_live()
# failed for practice, so the one screen built for testing a fight was the one screen where the
# payment cues never played. The promise practice makes ("leaves no footprint") is now kept at the
# exit instead: the fight pays for real and the purse is handed back on the way out.
#
# Asserts both halves: coins fly DURING the fight, and the run's gold is unchanged AFTER it.
#
#   godot --path D:\Godot\CardGame res://dev/_practice_pay.tscn


func _ready() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()
	var run := GameData.current_run
	var before := run.gold

	# A practice encounter, exactly as the gym builds one.
	var enc := EncounterData.new()
	enc.practice = true
	GameData.current_encounter = enc

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
	var bag = combat.get("_gold_bag")
	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			sv.add_child(vc)

	var victim := CardInstance.from_data(CardData.get_card("queen"))   # 5 cost = 5 coins
	board.place_enemy_card(victim, BoardLocation.at(1, 1, 1))
	await get_tree().process_frame
	Resolver.set_health(victim, 0)
	combat.call("_bury", victim)

	# Coins in the air, and the purse actually moved.
	var seen := 0
	for frame in 60:
		await get_tree().process_frame
		for band: Node in sv.find_children("*", "CanvasLayer", true, false):
			for fx: Node in band.get_children():
				if fx is TextureRect:
					seen = maxi(seen, 1)
	print("PRACTICE coins_seen=%s  gold_during=%d (was %d)  bag_shows=%s"
			% [seen > 0, run.gold, before, bag.get("_shown")])

	# ...and the exit hands it all back.
	await combat.call("_handle_combat_end")
	print("AFTER end: gold=%d  expected=%d  RESTORED=%s"
			% [run.gold, before, run.gold == before])
	get_tree().quit()
