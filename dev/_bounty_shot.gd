extends Node
# Probe for the kill-bounty feature: stages a real combat, kills an enemy unit through the real
# death path, and captures the coin stream mid-flight. Pass "king" to instead fell the enemy King
# and capture the treasure chest sitting in its slot.
#
#   godot --path . res://dev/_bounty_shot.tscn -- [king] [open] [WxH]
#
# Writes res://dev/_render_out.png (gitignored scratch, like the rest of dev/).

const OUT := "res://dev/_render_out.png"
var RES := Vector2i(1920, 1080)


func _arg_f(args: PackedStringArray, prefix: String, fallback: float) -> float:
	for a: String in args:
		if a.begins_with(prefix):
			return float(a.trim_prefix(prefix))
	return fallback


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for a: String in args:
		if a.contains("x") and a.split("x")[0].is_valid_int():
			RES = Vector2i(int(a.split("x")[0]), int(a.split("x")[1]))
	GameData.select_slot(0)
	GameData.start_new_run()
	GameData.current_run.relics.append_array(["battle_standard", "iron_aegis", "mana_font"])

	var sv := SubViewport.new()
	sv.size = RES
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

	if "endgame" in args:
		# The WHOLE chain, end to end: King dies → chest pops out of the burst → the player opens
		# it → the orb flies to the centre → combat navigates and the reward screen grows out of
		# the orb. "growat=" picks the moment of the capture, mid-growth.
		var enc := EncounterData.new()
		enc.type = EncounterData.Type.ELITE
		enc.gold_reward = 45
		enc.exp_reward = 3
		enc.material_rewards = {"fire": 2}
		GameData.current_encounter = enc
		var ek2: CardInstance = null
		for u: CardInstance in board.get_all_units():
			if u.owner == 1 and u.data.is_king:
				ek2 = u
		# INERT (2026-08-13 ruling): staging the kill rode the nuked write form.
		combat.call("_bury", ek2)
		combat.call("_handle_combat_end")          # awaits the chest, exactly as the real loop does
		await get_tree().create_timer(2.6).timeout  # burst + chest flight + landing
		combat.get("_reward_chest").call("_open_it")
		await get_tree().create_timer(_arg_f(args, "growat=", 1.3)).timeout
	elif "king" in args:
		# The enemy King, felled: the celebratory fall then the chest dropping into its slot.
		var ek: CardInstance = null
		for u: CardInstance in board.get_all_units():
			if u.owner == 1 and u.data.is_king:
				ek = u
		# INERT (2026-08-13 ruling): staging the kill rode the nuked write form.
		combat.call("_bury", ek)
		# Real seconds, not frames: the harness renders far faster than 60fps, so a frame count
		# lands somewhere arbitrary in the sequence. "at=N" picks the moment to capture, which is
		# how each phase of the build/burst/pop is inspected one at a time.
		await get_tree().create_timer(_arg_f(args, "at=", 2.6)).timeout
		if "open" in args:
			var chest = combat.get("_reward_chest")
			chest.call("_open_it")
			await get_tree().create_timer(_arg_f(args, "openat=", 0.6)).timeout
	else:
		# A plain enemy unit killed: the bounty pays and the coins fly to the bag.
		# "big" = a 5-cost queen, i.e. five coins — the case that proves the stream reads as one
		# lane rather than a spray.
		var victim := CardInstance.from_data(CardData.get_card("queen" if "big" in args else "knight"))
		board.place_enemy_card(victim, BoardLocation.at(1, 1, 1))
		await get_tree().process_frame
		# INERT (2026-08-13 ruling): staging the kill rode the nuked write form.
		combat.call("_bury", victim)
		if "big" in args:
			await get_tree().create_timer(0.42).timeout   # mid-stream, every coin in the air
		elif "settle" in args:
			await get_tree().create_timer(2.0).timeout   # every coin home: the bag's tally
														  # must have caught up to the purse
		else:
			for i in 26:   # mid-flight: coins strung out between the corpse and the bag
				await get_tree().process_frame

	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			sv.add_child(vc)
	await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	if is_instance_valid(combat):
		print("BOUNTY SHOT gold=", GameData.current_run.gold,
				" bag_shows=", combat.get("_gold_bag").get("_shown"),
				" pending_exp=", combat.get("_pending_exp"),
				" gauge_pending=", combat.get("_exp_gauge").pending())
	else:
		print("BOUNTY SHOT combat has navigated away; gold=", GameData.current_run.gold)
	get_tree().quit()
