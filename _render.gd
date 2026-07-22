extends Node
# Throwaway render harness: boots autoloads + a real save, renders a screen (passed after `--`) into
# an exact-size SubViewport, saves a PNG. e.g. godot --path . res://_render.tscn -- res://scenes/X.tscn
const OUT := "res://_render_out.png"
var RES := Vector2i(1920, 1080)
func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else "res://scenes/game_world.tscn"
	# Optional WxH arg (e.g. "1366x768") overrides the render resolution.
	for a: String in args:
		if a.contains("x") and a.split("x")[0].is_valid_int():
			RES = Vector2i(int(a.split("x")[0]), int(a.split("x")[1]))
	GameData.select_slot(0)
	# Screens that read GameData.current_run need an active run with a populated deck.
	for needs_run in ["combination", "shop", "deck_build", "rest", "relic_event", "event", "combat", "map", "stage_cleared"]:
		if scene_path.contains(needs_run):
			GameData.start_new_run()
			GameData.current_run.charms.append_array(["sharpened", "sturdy", "swift", "warded"])
			# Combat now shows relics on its own left-edge strip — give it chips to render.
			GameData.current_run.relics.append_array(["battle_standard", "iron_aegis", "mana_font"])
			# Optional "deckN" arg (e.g. deck23): pad the run deck to N cards by repeating it.
			for a: String in args:
				if a.begins_with("deck") and a.trim_prefix("deck").is_valid_int():
					var deck: Array = GameData.current_run.deck
					var base := deck.size()
					var i := 0
					while deck.size() < int(a.trim_prefix("deck")):
						deck.append(DeckCard.make((deck[i % base] as DeckCard).id))
						i += 1
			break
	# Crafting screen "merged": append a combined (2-piece) card to the deck — with it, incompatible
	# pairings (3+ pieces) become reachable for testing the invalid status / gray-out states.
	if scene_path.contains("combination") and "merged" in args:
		var mc := CardData.combine(CardData.get_card("pawn"), CardData.get_card("pawn"))
		GameData.current_run.deck.append(DeckCard.make(mc.id))
	# Deck builder / viewer need a target deck handed off (normally from the Decks screen).
	if GameData.current_profile != null:
		var did: String = GameData.current_profile.selected_deck_id
		GameData.editing_deck_id = did
		GameData.viewing_deck_id = did
	if OS.get_cmdline_user_args().size() > 1 and OS.get_cmdline_user_args()[1] == "compact":
		UIScale._compact = true
	# Map: simulate being mid-run (one visited node, standing on the next) so all medallion
	# states render — visited check, current glow, reachable highlight, locked.
	if scene_path.contains("map") and args.size() > 1 and "midrun" in args:
		var md := MapData.generate(GameData.current_map_state.map_seed, 0.15, 3)
		var start: MapNodeData = md.floors[0][0]
		GameData.current_map_state.visited_nodes = [start.id]
		GameData.current_map_state.current_node_id = start.connections[0]
	# "forgeack": pretend the player already acknowledged the Forge "!" at this map position.
	if scene_path.contains("map") and "forgeack" in args:
		GameData.current_run.forge_alert_ack = "%d:%d" % [GameData.current_run.act,
				GameData.current_map_state.current_node_id]
	if scene_path.contains("map") and args.size() > 1 and "zoomed" in args:
		MapScreen._zoom_level = 1.6
	if scene_path.contains("reward") and args.size() > 1 and "charm" in args:
		# Standalone charm reward (the post-stage pick) — pending offers, no encounter.
		GameData.start_new_run()
		var coffers: Array = []
		var ckind := ItemKinds.get_kind("charm")
		if ckind != null:
			for cid: String in ckind.offer_pool(4, null):
				coffers.append(Grant.make("charm", cid))
		GameData.pending_reward_offers = coffers
		GameData.pending_reward_title = "Stage Cleared — Choose a Charm"
		GameData.pending_reward_advance_stage = true
	elif scene_path.contains("reward"):
		var enc := EncounterData.new()
		enc.type = EncounterData.Type.ELITE
		enc.gold_reward = 45
		enc.exp_reward = 3
		enc.material_rewards = {"fire": 2, "water": 1, "knight_piece": 1}
		# Elite reward: a relic/charm choice (mirrors EncounterTemplateData._roll_elite_offers).
		var eoffers: Array = []
		var rk := ItemKinds.get_kind("relic")
		var chk := ItemKinds.get_kind("charm")
		var rids: Array = rk.offer_pool(2, null) if rk != null else []
		var cids: Array = chk.offer_pool(2, null) if chk != null else []
		for rid: String in rids:
			eoffers.append(Grant.make("relic", rid))
		for cid: String in cids:
			eoffers.append(Grant.make("charm", cid))
		enc.reward_offers = eoffers
		GameData.current_encounter = enc
	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	# Boot the real persistent Shell (not the bare screen) so the render shows the actual chrome
	# under test — screens no longer carry their own header/background since the Shell refactor.
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.auto_start = false
	sv.add_child(shell)
	shell.mount(scene_path)
	await get_tree().process_frame
	# Crafting screen "pair": pre-select two deck cards so the station previews a merge.
	# "pair" = first two; "pairI-J" (e.g. pair12-13) selects specific entry indices.
	for a: String in args:
		if scene_path.contains("combination") and a.begins_with("pair"):
			var ij := a.trim_prefix("pair").split("-")
			var i := int(ij[0]) if ij.size() == 2 else 0
			var j := int(ij[1]) if ij.size() == 2 else 1
			for n: Node in sv.find_children("*", "Control", true, false):
				if n.has_method("_on_tap"):
					n.call("_on_tap", {"kind": "card", "idx": i})
					if j != i:   # pairI-I = a SINGLE selection (one filled slot)
						n.call("_on_tap", {"kind": "card", "idx": j})
					break
	# Crafting screen "drag": simulate an in-flight drag of the LAST deck entry (combine with
	# "merged" so the dragged 2-piece card grays out its incompatible targets).
	if scene_path.contains("combination") and "drag" in args:
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_begin_drag"):
				n.call("_begin_drag", {"kind": "card", "idx": GameData.current_run.deck.size() - 1})
				break
	# "abilities": field an ability-holder (rook/castling) on the player board and open the
	# hand's level-2 Abilities view — i.e. the "Inspect Abilities" button pressed ON.
	if scene_path.contains("combat") and "abilities" in args:
		var combat: Node = null
		for n: Node in sv.find_children("*", "Node", true, false):
			if n.has_method("get_chrome") and n.get("_board") != null:
				combat = n
				break
		if combat != null:
			var board = combat.get("_board")
			var hand = combat.get("_hand")
			var rk := CardInstance.from_data(CardData.get_card("rook"))
			board.spawn_player_card(rk, 2, 1)
			if "armed" in args:
				rk.autocast_ability = "castling"
			await get_tree().process_frame
			if "inspectunit" in args:
				# "longdesc": stress the fixed-height guarantee with a wall of text.
				if "longdesc" in args:
					rk.data.description = "A truly enormous wall of rules text that goes on and on and on, well past any reasonable card, precisely to prove the inspect panel refuses to grow one pixel taller no matter how much prose is crammed into it. More. And more. And even more still."
				hand.set_inspected(rk)
			else:
				hand.show_abilities()
			await get_tree().process_frame
	# "inspect": pop the full-screen CardInspector over the scene (a content-rich card).
	if "inspect" in args:
		var ci := CardInstance.from_data(CardData.get_card("rook"))
		ci.owner = 0
		CardInspector.open(shell, ci)
	# "relic": pop the RelicInspector (map variant, with the Discard button).
	if "relic" in args:
		RelicInspector.open(shell, RelicData.get_relic("battle_standard"), true)
	# "settings": pop the header gear's settings overlay.
	if "settings" in args:
		SettingsOverlay.open(shell)
	# Upgrades: select a specific tree tab (pass its id after the scene path).
	if scene_path.contains("upgrades") and args.size() > 1:
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_select_tree"):
				n.call("_select_tree", args[1])
				break
	# Vfx is an autoload: its CanvasLayer hangs off the root, OUTSIDE this SubViewport, so
	# attached effects (glows/radiance) never reach the capture. Reparent it in.
	var vlayer: CanvasLayer = Vfx._layer
	if vlayer != null and vlayer.get_parent() != null:
		vlayer.get_parent().remove_child(vlayer)
		sv.add_child(vlayer)
	# Sustained radiance breathes from zero — let it climb to a visible phase before capture.
	for i in 40:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ", scene_path, " @ ", RES)
	get_tree().quit()
