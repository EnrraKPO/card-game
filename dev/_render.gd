extends Node
# Throwaway render harness: boots autoloads + a real save, renders a screen (passed after `--`) into
# an exact-size SubViewport, saves a PNG. e.g. godot --path . res://dev/_render.tscn -- res://scenes/X.tscn
const OUT := "res://dev/_render_out.png"
var RES := Vector2i(1920, 1080)
func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else "res://scenes/game_world.tscn"
	# Optional WxH arg (e.g. "1366x768") overrides the render resolution.
	for a: String in args:
		if a.contains("x") and a.split("x")[0].is_valid_int():
			RES = Vector2i(int(a.split("x")[0]), int(a.split("x")[1]))
	for a: String in args:
		if a.begins_with("loc="):
			Loc._lang = a.trim_prefix("loc=")   # non-persistent locale override for screenshots
		if a.begins_with("pace="):
			# Non-persistent pacing override (index into Vfx.PACING) — sets the in-memory preference
			# WITHOUT Vfx.set_overlap, so shooting the pacing states never writes the dev machine's
			# own user:// settings. Same shape as the locale override above.
			var pi := int(a.trim_prefix("pace="))
			Vfx._overlap_pref = float(Vfx.PACING[clampi(pi, 0, Vfx.PACING.size() - 1)]["overlap"])
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
	# Combat "enc=<template id>": launch the screen with a REAL encounter, the way the Combat Gym
	# does, so the CPU has an actual deck/hand instead of the no-encounter fallback (whose legacy
	# card ids resolve to nothing — the enemy stands there with an empty hand, which makes the
	# enemy readout impossible to judge). Optional "depth=N" picks the power ramp.
	if scene_path.contains("combat"):
		var depth := 0
		for a: String in args:
			if a.begins_with("depth="):
				depth = int(a.trim_prefix("depth="))
		for a: String in args:
			if a.begins_with("enc="):
				var want_id := a.trim_prefix("enc=")
				var tpl: EncounterTemplateData = null
				for t: EncounterTemplateData in EncounterTemplateData.all():
					if t.id == want_id:
						tpl = t
						break
				if tpl != null:
					var erng := RandomNumberGenerator.new()
					erng.seed = 4242
					var enc2 := tpl.instantiate(erng, EncounterTemplateData.power_for_depth(depth))
					enc2.practice = true
					GameData.current_encounter = enc2
	# Crafting screen "merged": append a combined (2-piece) card to the deck — with it, incompatible
	# pairings (3+ pieces) become reachable for testing the invalid status / gray-out states.
	if scene_path.contains("combination") and "merged" in args:
		var mc := CardData.combine(CardData.get_card("pawn"), CardData.get_card("pawn"))
		GameData.current_run.deck.append(DeckCard.make(mc.id))
	# "mineral=N" / "quickmerge": the two states the crafting table's engage fabs read from —
	# an empty purse (unaffordable pairs go unlit) and the quick-merge toggle switched on.
	for a: String in args:
		if a.begins_with("mineral=") and GameData.current_run != null:
			GameData.current_run.magic_mineral = int(a.trim_prefix("mineral="))
	if "quickmerge" in args and GameData.current_profile != null:
		GameData.current_profile.quick_merge = true
		GameData.current_profile.quick_merge_ack = true
	if "quickpreview" in args and GameData.current_profile != null:
		GameData.current_profile.quick_preview = true
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
	# "labnew": force the world screen's Lab button into its "NEW" state (first King Piece earned,
	# Lab never opened) — the AttentionBadge pill + host glow.
	if scene_path.contains("game_world") and "labnew" in args and GameData.current_profile != null:
		GameData.current_profile.lab_visited = false
		GameData.current_profile.unlocked_achievements.append(Achievements.FIRST_MATCH)
	# "nomineral": spend the run's Magic Mineral, so the Forge button shows its UNLIT state (no
	# glow, no inner light, no bubbling — the whole alert state is one gate).
	if scene_path.contains("map") and "nomineral" in args:
		GameData.current_run.magic_mineral = 0
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
	# "charmed": attach charms to the first deck cards so the on-card pips render.
	if "charmed" in args and GameData.current_run != null:
		var dk: Array = GameData.current_run.deck
		if dk.size() > 2:
			# One charm each: a base card is ONE component, so it bears exactly one
			# (see DeckCard.charm_capacity).
			(dk[0] as DeckCard).add_charm("sturdy")
			(dk[1] as DeckCard).add_charm("vampiric")
			(dk[2] as DeckCard).add_charm("thorned")
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
	# Crafting screen "pair": select a source card and (via its per-target merge button path)
	# open the merge framing. "pair" = first two; "pairI-J" selects specific entry indices;
	# "pairI-I" = a SINGLE selection (no merge opened).
	for a: String in args:
		if scene_path.contains("combination") and a.begins_with("pair"):
			var ij := a.trim_prefix("pair").split("-")
			var i := int(ij[0]) if ij.size() == 2 else 0
			var j := int(ij[1]) if ij.size() == 2 else 1
			for n: Node in sv.find_children("*", "Control", true, false):
				if n.has_method("_on_tap"):
					n.call("_on_tap", {"kind": "card", "idx": i})
					if j != i:
						n.call("_on_merge_btn", j)
					break
	# Crafting screen "previewinspect": run AFTER a pair selection with quickpreview on. Fires a real
	# right-click at the centre of the first quick-preview stand-in — the gesture the player makes —
	# so the shot proves WHICH card the inspector opened for, and that it came up phantom.
	if scene_path.contains("combination") and "previewinspect" in args:
		await get_tree().process_frame
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_reconcile_previews"):
				var pvs: Dictionary = n.get("_preview_uis")
				for k: int in pvs:
					var pv: Control = pvs[k]
					var click := InputEventMouseButton.new()
					click.button_index = MOUSE_BUTTON_RIGHT
					click.pressed = true
					click.position = pv.get_global_rect().get_center()
					click.global_position = click.position
					sv.push_input(click)
					print("PREVIEWINSPECT: right-clicked the stand-in on entry ", k)
					break
				break
		await get_tree().process_frame
	# Crafting screen "previewtip": pops the hover tooltip of the first quick-preview stand-in
	# through the real path (CardUI._make_custom_tooltip), so the shot shows whether the enlarged
	# card inside the tooltip agrees with the phantom the cursor is pointing at.
	if scene_path.contains("combination") and "previewtip" in args:
		await get_tree().process_frame
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_reconcile_previews"):
				var pvs: Dictionary = n.get("_preview_uis")
				for k: int in pvs:
					var pv: Control = pvs[k]
					var pcard: CardUI = pv.find_children("*", "CardUI", true, false)[0]
					var tip: Control = pcard._make_custom_tooltip("") as Control
					var cc := CenterContainer.new()
					cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
					cc.add_child(tip)
					var cl := CanvasLayer.new()
					cl.layer = 200
					cl.add_child(cc)
					sv.add_child(cl)
					print("PREVIEWTIP: tooltip for entry ", k, " phantom=", pcard.is_phantom)
					break
				break
		await get_tree().process_frame
	# Crafting screen "fabpress": presses at the CENTRE OF THE MERGE FLASK, which overlaps the
	# stand-in it rides. The selection must still be the SOURCE card afterwards — if the press leaks
	# through to the card under the flask, the source becomes the target and the merge is a card
	# with itself. Prints the selection before and after.
	if scene_path.contains("combination") and "fabpress" in args:
		await get_tree().process_frame
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_reconcile_previews"):
				var before: Dictionary = n.get("_sel")
				var fabs: Dictionary = n.get("_merge_btns")
				for k: int in fabs:
					var fab: Control = fabs[k]
					for down: bool in [true, false]:
						var click := InputEventMouseButton.new()
						click.button_index = MOUSE_BUTTON_LEFT
						click.pressed = down
						click.position = fab.get_global_rect().get_center()
						click.global_position = click.position
						sv.push_input(click)
					await get_tree().process_frame
					print("FABPRESS: flask of entry ", k, "  _sel before=", before,
							"  after=", n.get("_sel"), "  merge=", n.get("_merge").get("tgt", "none"))
					break
				break
		await get_tree().process_frame
	# Crafting screen "previewpress": the OTHER half of the stand-in's input contract — a real LEFT
	# press+release on a stand-in must still select the card underneath (the stand-in claims only the
	# gestures that ask a question). Prints the resulting selection so the regression is checkable.
	if scene_path.contains("combination") and "previewpress" in args:
		await get_tree().process_frame
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_reconcile_previews"):
				var pvs: Dictionary = n.get("_preview_uis")
				for k: int in pvs:
					var pv: Control = pvs[k]
					for down: bool in [true, false]:
						var click := InputEventMouseButton.new()
						click.button_index = MOUSE_BUTTON_LEFT
						click.pressed = down
						click.position = pv.get_global_rect().get_center()
						click.global_position = click.position
						sv.push_input(click)
					print("PREVIEWPRESS: pressed stand-in of entry ", k, " -> _sel=", n.get("_sel"))
					break
				break
		await get_tree().process_frame
	# Crafting screen "dropI-J": drives a real DRAG of entry I released over entry J — the path a
	# quick merge takes when it fuses out of the drop point rather than the grid slot.
	for a: String in args:
		if scene_path.contains("combination") and a.begins_with("drop"):
			var ij := a.trim_prefix("drop").split("-")
			var i := int(ij[0]) if ij.size() == 2 else 0
			var j := int(ij[1]) if ij.size() == 2 else 1
			for n: Node in sv.find_children("*", "Control", true, false):
				if n.has_method("_begin_drag"):
					var entries: Array = n.get("_entries")
					var tgt: Control = entries[j].item
					n.call("_begin_drag", {"kind": "card", "idx": i})
					n.call("_update_drag", tgt.get_global_rect().get_center())
					n.call("_resolve_drag")
					break
	# Crafting screen "quickask": flips the header's Quick merge toggle on with the profile
	# un-acknowledged, i.e. the first-enable path — renders the confirmation overlay.
	if scene_path.contains("combination") and "quickask" in args:
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_on_quick_merge_toggled"):
				n.call("_on_quick_merge_toggled", true)
				break
		await get_tree().process_frame
	# Crafting screen "toast": run AFTER a pair opens a merge (e.g. "pair10-12 toast") — drops the
	# framing and jumps straight to the celebration result toast for that pairing.
	if scene_path.contains("combination") and "toast" in args:
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_show_result_toast"):
				var merge_d: Dictionary = n.get("_merge")
				if merge_d != null and not merge_d.is_empty():
					n.call("_drop_cluster")
					var verdict: Dictionary = merge_d.get("verdict", {})
					n.call("_show_result_toast", verdict.get("preview"), "¡Forjado!")
				break
		await get_tree().process_frame
	# Crafting screen "charmsel": select the first charm only (the charm-chip Highlight state).
	if scene_path.contains("combination") and "charmsel" in args:
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_on_tap"):
				n.call("_on_tap", {"kind": "charm", "id": GameData.current_run.charms[0]})
				break
	# Crafting screen "charmpair": stage the ATTACH merge — select the first charm, then commit
	# to a bearer through the per-target button path.
	if scene_path.contains("combination") and "charmpair" in args:
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_on_tap"):
				n.call("_on_tap", {"kind": "charm", "id": GameData.current_run.charms[0]})
				n.call("_on_merge_btn", 0)
				break
	# Crafting screen "drag": simulate an in-flight drag of the LAST deck entry (combine with
	# "merged" so the dragged 2-piece card grays out its incompatible targets).
	if scene_path.contains("combination") and "drag" in args:
		for n: Node in sv.find_children("*", "Control", true, false):
			if n.has_method("_begin_drag"):
				n.call("_begin_drag", {"kind": "card", "idx": GameData.current_run.deck.size() - 1})
				break
	# "packed": fill BOTH boards to their back rows — the crowded case the turn-order strip has to
	# survive (sixteen entries in one narrow gutter), and a fuller stage for any combat shot.
	if scene_path.contains("combat") and "packed" in args:
		var pcombat: Node = null
		for n: Node in sv.find_children("*", "Node", true, false):
			if n.has_method("get_chrome") and n.get("_board") != null:
				pcombat = n
				break
		if pcombat != null:
			var pboard = pcombat.get("_board")
			var fodder := ["pawn", "bishop", "knight", "rook"]
			for r in BoardData.ROWS:
				for c in BoardData.COLS:
					var pid: String = fodder[(r * BoardData.COLS + c) % fodder.size()]
					if pboard.player_grid[r][c] == null:
						pboard.spawn_player_card(CardInstance.from_data(CardData.get_card(pid)), BoardLocation.at(0, r, c))
					if pboard.enemy_grid[r][c] == null:
						var foe := CardInstance.from_data(CardData.get_card(fodder[(c + r) % fodder.size()]))
						foe.owner = 1
						pboard.place_enemy_card(foe, BoardLocation.at(1, r, c))
			for _f in 20:
				await get_tree().process_frame
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
			# "holder=<card id>": field a specific ability-bearing unit (e.g. holder=knight_rook,
			# whose TWO abilities stress the inspect strip's width).
			var holder_id := "rook"
			for a: String in args:
				if a.begins_with("holder="):
					holder_id = a.trim_prefix("holder=")
			var rk := CardInstance.from_data(CardData.get_card(holder_id))
			board.spawn_player_card(rk, BoardLocation.at(0, 2, 1))
			await get_tree().process_frame
			if "inspectunit" in args:
				# "longdesc": stress the fixed-height guarantee with a wall of text.
				if "longdesc" in args:
					rk.data.description = "A truly enormous wall of rules text that goes on and on and on, well past any reasonable card, precisely to prove the inspect panel refuses to grow one pixel taller no matter how much prose is crammed into it. More. And more. And even more still."
				hand.set_inspected(rk)
			elif "list" in args:
				hand.show_abilities()
			else:
				# Stay on the plain hand: the Inspect Abilities button shows here (glowing when an
				# ability is castable now).
				hand.refresh_nav()
			await get_tree().process_frame
	# "handselect": select a unit card in hand — the shot of the SELECTION treatment itself
	# (CardUI derives it from Selection → the canonical `highlight`: grown in place, outlined
	# silhouette, dense glow), which must read the same here as on the crafting table.
	if scene_path.contains("combat") and "handselect" in args:
		var cbs: Node = null
		for n: Node in sv.find_children("*", "Node", true, false):
			if n.has_method("get_chrome") and n.get("_board") != null:
				cbs = n
				break
		if cbs != null:
			var shand = cbs.get("_hand")
			# The opening draw is animated: wait for a hand card to exist. A hand card is any
			# CardUI NOT parented to a board slot (the Hand's row isn't under the Hand node).
			var pick: CardUI = null
			for _w in 120:
				for n2: Node in sv.find_children("*", "", true, false):
					var c2 := n2 as CardUI
					if c2 != null and c2.card_instance != null and not c2.card_instance.is_spell \
							and (c2.get_parent() as SlotUI) == null:
						pick = c2
						break
				if pick != null:
					break
				await get_tree().process_frame
			# "fullhand": pad the hand until the strip overflows — the case where the lift is
			# traded back for a correct scroll (Hand._sync_strip_clip).
			if "fullhand" in args:
				for _e in 10:
					shand._spawn_hand_card(CardInstance.from_data(CardData.get_card("pawn")))
				for _f in 4:
					await get_tree().process_frame
			if pick != null:
				shand._toggle_select(pick)
			await get_tree().process_frame
			print("HANDSELECT: selected=%s strip clip=%s (content %.0f / scroll %.0f)" % [
					shand.selected().card_instance.data.id if shand.selected() != null else "none",
					shand._scroll.clip_contents, shand._content.size.x, shand._scroll.size.x])
	# "attackpreview": stage the attack-target preview — a selected friendly unit lighting the
	# enemy it will strike (red crosshair + glow), plus a landing phantom in an empty slot.
	if scene_path.contains("combat") and "attackpreview" in args:
		var cb: Node = null
		for n: Node in sv.find_children("*", "Node", true, false):
			if n.has_method("get_chrome") and n.get("_board") != null:
				cb = n
				break
		if cb != null:
			var board = cb.get("_board")
			var ep := CardInstance.from_data(CardData.get_card("pawn"))
			board.place_enemy_card(ep, BoardLocation.at(1, 1, 0))
			# An enemy in the bishop's lane — it targets our bishop, so it wears the incoming-threat
			# glow + attack-badge highlight (distinct from the crosshair on the bishop's OWN target).
			var pawn03 := CardInstance.from_data(CardData.get_card("pawn"))
			# Give it status pips (which overhang the card edge) to PROVE the composited glow leaves
			# every child uncovered — the glow is hollow over the real silhouette, pips included.
			for sid in ["barrier", "empowered"]:
				var sd := StatusData.get_status(sid)
				if sd != null:
					pawn03.statuses.append(StatusInstance.make(sd, 2, 2, null))
			board.place_enemy_card(pawn03, BoardLocation.at(1, 0, 3))
			var atk := CardInstance.from_data(CardData.get_card("bishop"))
			board.spawn_player_card(atk, BoardLocation.at(0, 1, 3))
			await get_tree().process_frame
			# "dragstart": exercise the drag-start selection fix — a fielded unit's drag with the
			# cursor still on its origin (no landing-slot hover) must still show its attack preview.
			if "handdrag" in args:
				# A hand-card PLACEMENT drag with the phantom on a landing slot: the menace
				# read must derive from the DECLARED spot (the hand card's own row is -1 —
				# measuring from it was the "menace never updates" defect). The fielded bishop
				# is removed first so the pivot is the enemies' only nearby mark — with it, a
				# correct derivation MUST light all three enemies; the broken one lit none.
				board.world.locations.undock(atk)
				(board.player_slots[1][3] as SlotUI).clear_card()
				var hand = cb.get("_hand")
				board._on_unit_drag_started(hand._hand_cards[0])
				await get_tree().process_frame
				board.set_process(false)   # freeze BEFORE mounting (no real cursor here)
				board._set_phantom_slot(board.player_slots[1][1])
			elif "dragstart" in args:
				board._on_unit_drag_started(board.get_card_ui(atk))
			elif "enemysel" in args:
				# Selecting an ENEMY unit: same action, no destinations fall out of the roles —
				# just its projection (crosshair on ITS target, menace glow on who targets it).
				board.interaction.begin(board.make_unit_action(board.get_card_ui(ep), false, false))
			else:
				# Stage the selection through the real path: a static UNIT action renders the
				# move cues AND the attack preview from one declaration (see Interaction).
				board.interaction.begin(board.make_unit_action(board.get_card_ui(atk), false, false))
			# "reticle": also mark the bishop's target enemy as a valid cast target, so the slot
			# shows BOTH the green reticle (centre) AND the attack crosshair (top-right) composed.
			if "reticle" in args:
				var tgt = board.find_target(atk)
				if tgt != null:
					var tslot = board.slot_of(tgt)
					if tslot != null:
						tslot.set_cue(SlotUI.Cue.TARGET_OK)
			if "enemysel" not in args and "handdrag" not in args:
				# The [0][1] phantom belongs to the player-selection staging (handdrag mounts
				# its own and removed atk from the board entirely).
				var pslot = board.player_slots[0][1]
				pslot.mount_phantom(board.get_card_ui(atk).make_ghost_view())
			# "hover": the cursor-hover read on a static selection — thick white outline on the
			# hovered destination slot, its MOVE arrow bobbing (frozen mid-bob in the shot).
			# Processing off first: the live poll would instantly re-derive from the real cursor
			# (parked at 0,0 in a harness run) and clear the staged hover.
			if "hover" in args:
				board.set_process(false)
				board._set_hover_slot(board.player_slots[2][1])
			await get_tree().process_frame
	# "lunge": a frame FROZEN mid-strike — the attacker out on its stand-in ghost, its real card
	# concealed in its slot. Then re-derives the concealed card and re-runs the tint appliers that
	# used to stomp the hide (set_exhausted / set_selected both write `modulate` wholesale), so the
	# shot proves the concealment survives exactly what broke it: ONE bishop on screen, its home
	# slot empty. Add "clobber" to also hammer it with the appliers directly.
	if scene_path.contains("combat") and "lunge" in args:
		var cb3: Node = null
		for n: Node in sv.find_children("*", "Node", true, false):
			if n.has_method("get_chrome") and n.get("_board") != null:
				cb3 = n
				break
		if cb3 != null:
			var board3 = cb3.get("_board")
			var victim := CardInstance.from_data(CardData.get_card("pawn"))
			board3.place_enemy_card(victim, BoardLocation.at(1, 1, 0))
			var striker := CardInstance.from_data(CardData.get_card("bishop"))
			board3.spawn_player_card(striker, BoardLocation.at(0, 1, 3))
			await get_tree().process_frame
			var s_card: CardUI = board3.get_card_ui(striker)
			var v_card: CardUI = board3.get_card_ui(victim)
			var ghost3: CardUI = cb3.get("_animator").spawn_ghost(s_card)
			CombatContext.current.declare_stand_in(striker, ghost3)
			s_card.derive_presentation()
			# Park the ghost where the lunge's rebound leaves it — beside the victim.
			ghost3.global_position = Vector2(
				v_card.global_position.x + v_card.size.x + 12.0, v_card.global_position.y)
			if "clobber" in args:
				striker.attack_exhausted = true
				s_card.set_exhausted(true)
				Selection.select(striker)
				s_card.derive_presentation()
			await get_tree().process_frame
	# "burning": set ground alight — an occupied enemy cell and an empty player cell — so the
	# slot-layer presentation can be shot both ways (wash + pip over a unit, and on bare ground).
	if scene_path.contains("combat") and "burning" in args:
		var cbg: Node = null
		for n: Node in sv.find_children("*", "Node", true, false):
			if n.has_method("get_chrome") and n.get("_board") != null:
				cbg = n
				break
		if cbg != null:
			var gboard = cbg.get("_board")
			var victim := CardInstance.from_data(CardData.get_card("pawn"))
			gboard.place_enemy_card(victim, BoardLocation.at(1, 1, 0))
			var gworld: CombatWorld = gboard.world
			StatusEngine.apply(gworld.slot_at(1, 1, 0), "burning", StatusEngine.DURATION_DEFAULT, 1, null)
			StatusEngine.apply(gworld.slot_at(0, 2, 1), "burning", StatusEngine.DURATION_DEFAULT, 1, null)
			gboard.refresh()
			await get_tree().process_frame
	# ("armeddrag" retired with the armed-autocast gesture — effect-cleanse demolition.)
	# "inspect": pop the full-screen CardInspector over the scene (a content-rich card).
	# "stattip": a single stat badge's rich hover tooltip (colour-named), built directly since a real
	# hover can't be staged. Pass stat=<health|shield|attack|speed> to pick which.
	if "stattip" in args:
		var stat := "speed"
		var scid := "knight"
		for a: String in args:
			if a.begins_with("stat="):
				stat = a.trim_prefix("stat=")
			if a.begins_with("card="):
				scid = a.trim_prefix("card=")
		var stips := CardTooltip.stat_tips(CardInstance.from_data(CardData.get_card(scid)))
		var st: Dictionary = stips[stat]
		var sbt := StatBadgeTip.new()
		sbt._title = st["title"]
		sbt._title_color = st["color"]
		sbt._body = st["body"]
		var tipnode: Control = sbt._make_custom_tooltip("")
		var scc := CenterContainer.new()
		scc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		scc.add_child(tipnode)
		var scl := CanvasLayer.new()
		scl.layer = 200
		scl.add_child(scc)
		sv.add_child(scl)
	# "hovertip": the compact hover CardTooltip (normally only shown by a real mouse hover),
	# centered on the scene so its yellow expand-footnote can be eyeballed.
	if "hovertip" in args:
		var hid := "knight"
		for a: String in args:
			if a.begins_with("card="):
				hid = a.trim_prefix("card=")
		var tip := CardTooltip.build(CardInstance.from_data(CardData.get_card(hid)), true)
		var cc := CenterContainer.new()
		cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cc.add_child(tip)
		var cl := CanvasLayer.new()
		cl.layer = 200
		cl.add_child(cc)
		sv.add_child(cl)
	if "inspect" in args:
		CardInspector._show_descriptions = "nodesc" not in args
		var insp_id := "rook"
		for a: String in args:
			if a.begins_with("card="):
				insp_id = a.trim_prefix("card=")
		var ci := CardInstance.from_data(CardData.get_card(insp_id))
		ci.owner = 0
		if "charmed" in args:
			ci.charms = ["sturdy", "vampiric", "thorned"]
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
	# Vfx is an autoload: its overlay CanvasLayers (the base band + any per-band layers a staged
	# modal created) hang off the root, OUTSIDE this SubViewport, so attached effects
	# (glows/radiance/highlights) never reach the capture. Reparent them all in. Bands created
	# AFTER this land beside the base band automatically (Vfx parents them at _layer's parent).
	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			sv.add_child(vc)
	# Sustained radiance breathes from zero — let it climb to a visible phase before capture.
	for i in 40:
		await get_tree().process_frame
	# "forgehover": simulate hovering the Forge button, to prove the badge's acknowledgement wiring
	# end to end — the mark goes quiet, its glow detaches with it, and the screen persists "seen".
	if scene_path.contains("map") and "forgehover" in args:
		for b: Node in sv.find_children("*", "AttentionBadge", true, false):
			var ab := b as AttentionBadge
			for ch: Node in ab.host.get_children():
				if ch is Button:
					(ch as Button).mouse_entered.emit()
			print("VFX ack: shown=%s attached=%s persisted=\"%s\""
					% [ab.shown, Vfx._attached.keys(), GameData.current_run.forge_alert_ack])
		await get_tree().process_frame
	# Combat "enemyhand": opens the DEBUG enemy-hand overlay the way clicking the EnemyIntel
	# readout does, so the modal can be shot without a mouse.
	if scene_path.contains("combat") and "enemyhand" in args:
		for n: Node in sv.find_children("*", "EnemyIntel", true, false):
			EnemyHandOverlay.open(n, (n as EnemyIntel)._side)
			break
		await get_tree().process_frame
		await get_tree().process_frame
	# "vfxdump": list what the VFX overlay bands are actually drawing at capture time — the answer
	# to "is this glow missing, or is it there and the capture can't see it?", which a screenshot
	# cannot distinguish (composited GlowFx quads have historically not survived the harness).
	if "vfxdump" in args:
		for b: Node in sv.find_children("*", "AttentionBadge", true, false):
			var ab := b as AttentionBadge
			print("VFX badge kind=%s shown=%s glow=%s rect=%s host=%s"
					% [ab.kind, ab.shown, ab.glow_id, ab.get_global_rect(), ab.host])
		print("VFX attached states: ", Vfx._attached.keys())
		var bands: Array[Node] = sv.find_children("*", "CanvasLayer", true, false)
		print("VFX bands in capture: %d (Vfx autoload still holds %d children)"
				% [bands.size(), Vfx.get_child_count()])
		for band: Node in bands:
			print("VFX band %s children=%d" % [band.name, band.get_child_count()])
			for fx: Node in band.get_children():
				var c := fx as Control
				if c != null:
					print("VFX   %s visible=%s rect=%s" % [c.get_class(), c.visible, c.get_global_rect()])
	# Combat "turnhover=N": points at the Nth entry of the turn-order strip the way a cursor does,
	# so the shot shows the strip AND the unit it lights on the board (see TurnOrderStrip).
	for a: String in args:
		if scene_path.contains("combat") and a.begins_with("turnhover"):
			var want := int(a.trim_prefix("turnhover=")) if a.contains("=") else 1
			for n: Node in sv.find_children("*", "TurnOrderStrip", true, false):
				var strip := n as TurnOrderStrip
				strip.refresh()
				var listed: Array = strip.listed()
				if want >= 1 and want <= listed.size():
					strip.point_at(listed[want - 1])
					print("TURNHOVER: entry %d -> %s" % [want, listed[want - 1].data.id])
				break
			for _f in 25:
				await get_tree().process_frame
	# Combat "turnmark=N": marks the Nth unit the way resting the cursor on its CARD does, so the
	# shot shows the list answering the board (the mirror of turnhover — see TurnOrderStrip).
	for a: String in args:
		if scene_path.contains("combat") and a.begins_with("turnmark"):
			var want := int(a.trim_prefix("turnmark=")) if a.contains("=") else 1
			for n: Node in sv.find_children("*", "TurnOrderStrip", true, false):
				var strip := n as TurnOrderStrip
				strip.refresh()
				var listed: Array = strip.listed()
				if want >= 1 and want <= listed.size():
					strip.mark(listed[want - 1])
					print("TURNMARK: entry %d -> %s" % [want, listed[want - 1].data.id])
				break
			for _f in 25:
				await get_tree().process_frame
	# "handflutter=N": swipe in and out of card N repeatedly, each time re-entering while the drop is
	# still in flight. Every peak must be the SAME height — a lift that reads its floor off a card
	# still on its way down climbs a little further each pass ("move up by this much" instead of
	# "move onto this position").
	for a: String in args:
		if not (scene_path.contains("combat") and a.begins_with("handflutter")):
			continue
		var want := int(a.split("=")[1]) if a.contains("=") else 1
		for n: Node in sv.find_children("*", "Hand", true, false):
			var cards: Array[Node] = (n as Hand)._hand_box.get_children()
			if want < 1 or want > cards.size():
				break
			var c := cards[want - 1] as CardUI
			var peaks := PackedStringArray()
			for _pass in 6:
				c.force_hover(true)
				for _f in 14:                    # part-way up, nowhere near settled
					await get_tree().process_frame
				peaks.append("%.1f" % c.position.y)
				c.force_hover(false)
				for _f in 6:                     # back out again BEFORE the drop finishes
					await get_tree().process_frame
			# THE decisive number: hold the hover after all that fluttering and let it settle. It must
			# land on exactly the same height a single clean hover reaches (see handhover=N), because
			# the target is an absolute position, not an increment on wherever the card happened to be.
			c.force_hover(true)
			for _f in 90:
				await get_tree().process_frame
			print("HANDFLUTTER card %d peaks: " % want, " ".join(peaks),
					" | settled after fluttering: %.1f" % c.position.y)
			break
	# "handswipe=A-B": the case that actually broke — moving from one hand card straight to another,
	# with no gap. The card being LEFT finishes its drop ~340ms later, and anything it does then must
	# not disturb the card now being hovered. Traces B's position across that whole window: it must
	# rise and STAY risen.
	for a: String in args:
		if not (scene_path.contains("combat") and a.begins_with("handswipe")):
			continue
		var pair := a.split("=")[1].split("-")
		for n: Node in sv.find_children("*", "Hand", true, false):
			var cards: Array[Node] = (n as Hand)._hand_box.get_children()
			var ia := int(pair[0]) - 1
			var ib := int(pair[1]) - 1
			if ia < 0 or ib < 0 or ia >= cards.size() or ib >= cards.size():
				break
			var ca := cards[ia] as CardUI
			var cb := cards[ib] as CardUI
			ca.force_hover(true)
			for _f in 40:
				await get_tree().process_frame
			# The swipe: A is left and B is entered in the same instant, as a pointer does.
			ca.force_hover(false)
			cb.force_hover(true)
			var trace := PackedStringArray()
			for _b in 14:
				for _f in 8:
					await get_tree().process_frame
				trace.append("%.1f" % cb.position.y)
			print("HANDSWIPE %d->%d, card %d y: " % [ia + 1, ib + 1, ib + 1], " ".join(trace))
			break
	# "cardhover=N" / "handhover=N": rests the cursor on the Nth turn-order unit's BOARD card, or on
	# the Nth card in the hand row, by emitting the signal a real cursor would (see CardUI._set_hovered).
	# The lift is ~2.5% of the card's height and deliberately subtle, so the print — rest position vs
	# lifted position — is the real verification; the shot only confirms nothing else moved with it.
	for a: String in args:
		var board_side := a.begins_with("cardhover")
		if not (scene_path.contains("combat") and (board_side or a.begins_with("handhover"))):
			continue
		var want := int(a.split("=")[1]) if a.contains("=") else 1
		var ui: CardUI = null
		if board_side:
			for n: Node in sv.find_children("*", "TurnOrderStrip", true, false):
				var strip := n as TurnOrderStrip
				strip.refresh()
				var listed: Array = strip.listed()
				if want >= 1 and want <= listed.size():
					ui = strip.board.get_card_ui(listed[want - 1])
				break
		else:
			for n: Node in sv.find_children("*", "Hand", true, false):
				var cards: Array[Node] = (n as Hand)._hand_box.get_children()
				if want >= 1 and want <= cards.size():
					ui = cards[want - 1] as CardUI
				break
		if ui == null:
			continue
		var was := ui.position
		# force_hover, not mouse_entered: there is no real pointer here for the cue's own per-frame
		# hit test to find (warp_mouse does not reach this SubViewport), so the hover has to be
		# latched. NOTE this means the harness stages the LOOK — the anti-oscillation hit test
		# itself needs a real cursor and real eyes.
		ui.force_hover(true)
		var trace := PackedStringArray()
		for _b in 12:
			for _f in 5:
				await get_tree().process_frame
			trace.append("%.1f" % ui.position.y)
		print("HOVERTRACE(%s): " % ["board" if board_side else "hand"], " ".join(trace))
		print("CARDHOVER(%s): #%d rest=%.1f lifted=%.1f (rise %.1fpx of %.0f tall)"
				% ["board" if board_side else "hand", want, was.y, ui.position.y,
				was.y - ui.position.y, ui.size.y])
	# "slothover=N": rests the cursor on the Nth EMPTY player slot. The slot answers a pointer only
	# while nobody is standing in it — an occupied one defers to its occupant's own ring (see
	# SlotUI._apply_hover_outline) — so this is the shot for the half of the board hover that has no
	# card in it. Entered directly for the same reason cardhover latches: warp_mouse does not reach
	# this SubViewport, so no real pointer can ever be inside the slot's rect.
	for a: String in args:
		if not (scene_path.contains("combat") and a.begins_with("slothover")):
			continue
		var want := int(a.split("=")[1]) if a.contains("=") else 1
		var seen := 0
		for n: Node in sv.find_children("*", "SlotUI", true, false):
			var slot := n as SlotUI
			if slot.location.side != 0 or slot.get_card() != null:
				continue
			seen += 1
			if seen != want:
				continue
			slot._on_pointer_entered()
			for _f in 30:
				await get_tree().process_frame
			print("SLOTHOVER: empty player slot #%d at %s" % [want, str(slot.location)])
			break
	# CombatBoard.press_unit, i.e. the same `slot_pressed` a press on the unit's own card takes. The
	# print says who ended up the pick, which is what the click is FOR.
	for a: String in args:
		if scene_path.contains("combat") and a.begins_with("turnclick"):
			var want := int(a.trim_prefix("turnclick=")) if a.contains("=") else 1
			for n: Node in sv.find_children("*", "TurnOrderStrip", true, false):
				var strip := n as TurnOrderStrip
				strip.refresh()
				var listed: Array = strip.listed()
				if want >= 1 and want <= listed.size():
					var unit: CardInstance = listed[want - 1]
					# Add "viaslot" to press the unit's own SLOT instead — the A/B that proves the
					# strip's door and a real card click land the card in the same visual state.
					# Reporting the card's SCALE is the point: a selection whose grow silently
					# became a no-op is invisible in a still, and that is exactly the bug this
					# caught (see HighlightFx._configure on the shared grow slot). Pair it with
					# turnhover=N to reproduce a click made while the strip is being read.
					if "viaslot" in args:
						(strip.board.slot_of(unit) as SlotUI).pressed.emit()
					else:
						strip.board.press_unit(unit)
					# Long enough for the grow tween to SETTLE, not just to be under way — a
					# mid-tween sample reads differently on every machine and every run, which is
					# useless for telling a real regression from timing noise.
					for _f in 90:
						await get_tree().process_frame
					var picked: CardInstance = Selection.current() as CardInstance
					var ui := strip.board.get_card_ui(unit)
					# The AUTHORED grow is printed beside the measured one: the entry is tool-tunable,
					# so "the card only grew 1.07" is a bug report about the code only if the data
					# still says 1.15. Reading the answer without the question wastes an hour.
					print("TURNCLICK(%s): entry %d (%s) -> pick=%s card scale=%.3f (authored %.3f) highlight=%s"
							% ["viaslot" if "viaslot" in args else "strip", want, unit.data.id,
							"nothing" if picked == null else picked.data.id, ui.scale.x,
							Vfx.param_of("highlight", "scale", 1.15),
							Vfx._attached.has("highlight@%d" % ui.get_instance_id())])
				break
			for _f in 25:
				await get_tree().process_frame
	# Combat "turnselect=N": makes the Nth unit the PICK, for the strip's inverted-skin cue. Selects
	# for REAL (Selection has no cursor in it), so the board card wears its own selection treatment
	# too and the shot shows both ends of the pick.
	for a: String in args:
		if scene_path.contains("combat") and a.begins_with("turnselect"):
			var want := int(a.trim_prefix("turnselect=")) if a.contains("=") else 1
			for n: Node in sv.find_children("*", "TurnOrderStrip", true, false):
				var strip := n as TurnOrderStrip
				strip.refresh()
				var listed: Array = strip.listed()
				if want >= 1 and want <= listed.size():
					Selection.select(listed[want - 1])
					print("TURNSELECT: entry %d -> %s" % [want, listed[want - 1].data.id])
				break
			for _f in 25:
				await get_tree().process_frame
	# Combat "turnacting=N": stands the round loop still on the Nth entry (CombatWorld.acting) and
	# taps the one after it, so one shot carries all three entry states — acting, spent, ready.
	for a: String in args:
		if scene_path.contains("combat") and a.begins_with("turnacting"):
			var want := int(a.trim_prefix("turnacting=")) if a.contains("=") else 1
			for n: Node in sv.find_children("*", "TurnOrderStrip", true, false):
				var strip := n as TurnOrderStrip
				strip.refresh()
				var listed: Array = strip.listed()
				if want >= 1 and want <= listed.size():
					strip.world.acting = listed[want - 1]
					print("TURNACTING: entry %d -> %s" % [want, listed[want - 1].data.id])
				if want < listed.size():
					(listed[want] as CardInstance).attack_exhausted = true
				break
			for _f in 25:
				await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ", scene_path, " @ ", RES)
	get_tree().quit()
