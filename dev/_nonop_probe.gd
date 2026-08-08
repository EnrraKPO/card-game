extends Node
# Throwaway: does PROHIBIT NON-OPS hold end to end in a real fight? Boots a combat, fields a
# healer beside a whole ally and asks the live gates — the ability's own usability derivation
# (CombatContext.ability_usable, what the tray widget greys itself by), the per-slot targeting
# judge the cues light from, and a hand spell's playability — then wounds the ally and asks
# again. Every line should flip from false to true on that one wound.
#   godot --path . res://dev/_nonop_probe.tscn
const HEALER := "air_air_bishop"   # holds the authored `heal` ability (health +2, manual)


func _say(line: String) -> void:
	print("PROBE: " + line)


func _report(combat: Node, healer: CardInstance, ally: CardInstance, when: String) -> void:
	var ctx: CombatContext = CombatContext.current
	var caster = combat.get("_spell_caster")
	var board = combat.get("_board")
	var ab := AbilityData.get_ability("heal")
	var slot: SlotUI = board.slot_of(ally)
	_say("%s: ally %d/%d | ability_usable=%s | ally is a legal pick=%s | has_a_play=%s" % [
		when, ally.current_health, ally.get_attribute("max_health"),
		ctx.ability_usable(healer, ab),
		caster.effects_target_ok(ab.effects, slot),
		caster.effects_have_a_play(ab.effects, healer)])


func _ready() -> void:
	await get_tree().process_frame
	GameData.current_slot = 0
	GameData.start_new_run()
	var combat: Control = load("res://scenes/combat.tscn").instantiate()
	add_child(combat)
	for _i in 30:
		await get_tree().process_frame

	var board = combat.get("_board")
	var healer := CardInstance.from_data(CardData.get_card(HEALER))
	board.spawn_player_card(healer, 0, 0)
	var ally := CardInstance.from_data(CardData.get_card("pawn"))
	board.spawn_player_card(ally, 0, 1)
	Resolver.fill_health(ally)
	for _i in 10:
		await get_tree().process_frame

	_report(combat, healer, ally, "whole board")
	ally.current_health -= 1
	_report(combat, healer, ally, "ally wounded")

	# The player King is the OTHER candidate on the board — with it whole and the ally wounded
	# the ability is legal, but the King itself must still refuse the pick.
	var king = board.get_player_king()
	var kslot: SlotUI = board.slot_of(king)
	var caster = combat.get("_spell_caster")
	var ab := AbilityData.get_ability("heal")
	_say("whole King is a legal pick=%s (must be false)" % [
		caster.effects_target_ok(ab.effects, kslot)])

	# A unit is a BODY: its playability must never depend on its effects doing anything.
	_say("a unit card still has a play=%s (must be true)" % [
		caster.card_has_a_play(CardInstance.from_data(CardData.get_card("pawn")))])
	get_tree().quit(0)
