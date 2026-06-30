extends Node
# Throwaway render harness: boots autoloads + a real save, renders a screen (passed after `--`) into
# an exact-size SubViewport, saves a PNG. e.g. godot --path . res://_render.tscn -- res://scenes/X.tscn
const OUT := "res://_render_out.png"
const RES := Vector2i(1920, 1080)
func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else "res://scenes/game_world.tscn"
	GameData.select_slot(0)
	# Screens that read GameData.current_run need an active run with a populated deck.
	for needs_run in ["combination", "shop", "deck_build", "rest", "relic_event", "event", "combat", "map"]:
		if scene_path.contains(needs_run):
			GameData.start_new_run()
			GameData.current_run.charms.append_array(["sharpened", "sturdy", "swift", "warded"])
			break
	# Deck builder / viewer need a target deck handed off (normally from the Decks screen).
	if GameData.current_profile != null:
		var did: String = GameData.current_profile.selected_deck_id
		GameData.editing_deck_id = did
		GameData.viewing_deck_id = did
	if scene_path.contains("reward"):
		var enc := EncounterData.new()
		enc.type = EncounterData.Type.ELITE
		enc.gold_reward = 45
		enc.exp_reward = 3
		enc.material_rewards = {"fire": 2, "water": 1, "knight_piece": 1}
		enc.reward_pool = ["fire_fire", "air_water", "earth_fire"]
		enc.relic_offer = "battle_standard"
		GameData.current_encounter = enc
	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	sv.add_child(load(scene_path).instantiate())
	for i in 8:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ", scene_path, " @ ", RES)
	get_tree().quit()
