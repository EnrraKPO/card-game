extends Node
# Probe for "the captain falls OUTSIDE the combat loop" — the defect this feature fixes: a fire
# spell that kills the enemy captain during the placement phase used to leave the fight running
# for another whole turn, and the sweep threw the body away so the fall and the chest never played.
#
# Stages a real combat, puts an enemy army on the board, then kills the captain THROUGH THE EFFECT
# PATH (EffectSystem damage + the sweep — what any resolved cast does) and asks the
# fight-may-have-ended question a finished cast asks. Then checks the four promises:
#   1. the fight ENDED there and then (no waiting for the next turn),
#   2. the captain got its fall — the treasure chest exists,
#   3. the army fell with it — no enemy unit still standing,
#   4. those deaths PAID (user call: real deaths, real bounties).
#
# Pass "combat" for the OTHER half of the feature: the captain cut down by a STRIKE, mid-round,
# where the promise is that the turn list stops on the spot instead of playing itself out over a
# corpse — and the army falls the same way it does above.
#
#   godot --path . res://dev/_captain_end_probe.tscn [-- combat]
#
# Runs without --headless (the VFX the sequence plays need a real viewport — see UI_OVERHAUL_GUIDE).

const ARMY := ["knight", "pawn", "pawn"]


func _ready() -> void:
	if "combat" in OS.get_cmdline_user_args():
		await _in_combat()
		return
	await _by_spell()


# ── The captain cut down mid-round: the round STOPS ────────────────────────────────────
func _in_combat() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()

	var sv := SubViewport.new()
	sv.size = Vector2i(1422, 800)
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
	var failures := 0

	# A captain on its last point of health, a player unit standing where it will reach it, and an
	# enemy army behind it whose turns come after — the units that must never get to swing.
	var king: CardInstance = board.get_enemy_king()
	Resolver.set_health(king, 1)
	king.current_shield = 0   # one point of health and nothing in front of it
	# The captain sits in the DEEPEST column, so a nearest-targeting hero would chew through the
	# army first and never reach it. A wounded-seeking hero goes straight for the one point of
	# health left standing — which is the whole staging: the captain dies with turns still queued.
	# TARGETING REMOVED (targeting-cleanup demolition): the wounded policy below is authored but
	# nothing interprets it, so this probe's combat half CANNOT PASS until targeting returns.
	var hero_def := CardData.scaled(CardData.get_card("queen"), 0.0)
	hero_def.target_policy = "wounded"
	hero_def.speed = 99   # it swings FIRST; the enemy turns behind it are the ones that must not
	var hero := CardInstance.from_data(hero_def)
	board.spawn_player_card(hero, BoardLocation.at(0, 1, 3))
	for i in ARMY.size():
		var unit := CardInstance.from_data(CardData.get_card(ARMY[i]))
		board.place_enemy_card(unit, BoardLocation.at(1, i % BoardData.ROWS, 1 + int(i / BoardData.ROWS)))
	await get_tree().process_frame
	var hero_hp: int = hero.current_health

	await combat.call("_on_done_pressed")
	await get_tree().create_timer(4.0).timeout

	if not combat.get("_ended"):
		failures += 1
		print("FAIL: the fight did NOT end the round the captain fell")
	if combat.get("_reward_chest") == null:
		failures += 1
		print("FAIL: no treasure chest — the captain's fall never played")
	var left: Array = BoardFacade.units_on_side(combat.get("_world"), 1)
	if not left.is_empty():
		failures += 1
		print("FAIL: %d enemy unit(s) still standing after the captain fell" % left.size())
	if hero.current_health < hero_hp:
		failures += 1
		print("FAIL: leaderless units still swung — the hero lost %d hp after the captain died"
				% (hero_hp - hero.current_health))

	print("CAPTAIN COMBAT PROBE: %s (turn %s)"
			% ["OK" if failures == 0 else "%d FAILURES" % failures, str(combat.get("_turn"))])
	get_tree().quit(0 if failures == 0 else 1)


# ── The captain killed by a spell, outside the combat loop ─────────────────────────────
func _by_spell() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()

	var sv := SubViewport.new()
	sv.size = Vector2i(1422, 800)
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
	var failures := 0

	# An army standing behind its captain, so the collapse has something to collapse.
	for i in ARMY.size():
		var unit := CardInstance.from_data(CardData.get_card(ARMY[i]))
		board.place_enemy_card(unit, BoardLocation.at(1, i % BoardData.ROWS, 1 + int(i / BoardData.ROWS)))
	await get_tree().process_frame
	var gold_before: int = GameData.current_run.gold

	# THE SPELL. Not a strike: a damage effect resolved and swept, which is the whole path the
	# defect lived on. The captain is dead and off the board the moment cleanup returns.
	var king: CardInstance = board.get_enemy_king()
	var burn := Effect.from_dict({
		"trigger": {"kind": "on_play"},
		"targets": {"kind": "manual"},
		"attribute": "health", "amount": -999,
	})
	var ctx: EffectContext = board.make_context(null)
	ctx.manual_target = king
	EffectSystem.apply_single(burn, null, ctx)
	board.cleanup_effect_deaths()

	if board.get_card_ui(king) == null:
		failures += 1
		print("FAIL: the sweep threw the captain's body away — nothing left to fall")

	# The question a finished cast makes the orchestrator ask (see Combat._settle_if_decided).
	await combat.call("_settle_if_decided")
	await get_tree().create_timer(3.5).timeout   # the fall, the chest, the army coming apart

	if not combat.get("_ended"):
		failures += 1
		print("FAIL: the fight did NOT end on the spot")
	if combat.get("_reward_chest") == null:
		failures += 1
		print("FAIL: no treasure chest — the captain's fall never played")
	var left: Array = BoardFacade.units_on_side(combat.get("_world"), 1)
	if not left.is_empty():
		failures += 1
		print("FAIL: %d enemy unit(s) still standing after the captain fell" % left.size())
	var paid: int = GameData.current_run.gold - gold_before
	if paid <= 0:
		failures += 1
		print("FAIL: the collapsing army paid nothing (%d gold)" % paid)

	print("CAPTAIN END PROBE: %s (gold paid %d, exp held %s)"
			% ["OK" if failures == 0 else "%d FAILURES" % failures, paid,
			str(combat.get("_pending_exp"))])
	get_tree().quit(0 if failures == 0 else 1)
