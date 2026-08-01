extends Node
# Throwaway: WHEN does the bomb's consumable chip stop being usable? Boots a real combat and
# samples the chip's own usability read (RelicTray.consumable_check, which the chip polls) at
# every interesting moment: the first placement turn, through a full resolved round, and after
# a fresh combat is mounted in the first one's place.
#   godot --path . res://dev/_bomb_lock_probe.tscn
const OUT := "user://bomb_lock_probe.txt"


func _say(line: String) -> void:
	print("PROBE: " + line)
	var f := FileAccess.open(OUT, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(OUT, FileAccess.WRITE)
	f.seek_end()
	f.store_line(line)
	f.close()


func _sample(combat: Node, when: String) -> void:
	var tray: RelicTray = combat.get("_relic_tray")
	var chip: ConsumableChip = null
	for c in tray.get_children():
		if c is ConsumableChip:
			chip = c
	var check: Callable = tray.consumable_check
	_say("%s: phase=%s modal_lock=%s busy=%s check=%s chip=%s chip_modulate_a=%.2f" % [
		when, combat.get("_phase"), combat.get("_modal_lock"), combat.get("_consumable_busy"),
		("-" if not check.is_valid() else str(bool(check.call()))),
		("missing" if chip == null else "present"),
		(0.0 if chip == null else chip.modulate.a)])


func _mount() -> Node:
	var combat: Control = load("res://scenes/combat.tscn").instantiate()
	add_child(combat)
	for _i in 30:
		await get_tree().process_frame
	return combat


func _ready() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT))
	await get_tree().process_frame
	GameData.current_slot = 0
	GameData.start_new_run()
	_say("relics: %s" % [GameData.current_run.relics])

	var combat := await _mount()
	_sample(combat, "combat 1, turn 1 placement")

	# A full round the way the player ends one: press Ready and let the resolution run out.
	combat.call("_on_done_pressed")
	for _i in 400:
		await get_tree().process_frame
	_sample(combat, "combat 1, after one resolved round")

	# The same, but with a MODAL aiming session left open when Ready is pressed — the state
	# _on_done_pressed never tears down.
	var hand = combat.get("_hand")
	var caster = combat.get("_spell_caster")
	var interaction = combat.get("_interaction")
	var spell_ui: CardUI = null
	for ui: CardUI in hand.get("_hand_cards"):
		if ui.card_instance.is_spell:
			spell_ui = ui
	if spell_ui != null:
		interaction.begin(caster.make_cast_action(spell_ui, false))
		await get_tree().process_frame
		_sample(combat, "combat 1, modal aim open")
		combat.call("_on_done_pressed")
		for _i in 400:
			await get_tree().process_frame
		_sample(combat, "combat 1, round ended UNDER a modal aim")
	else:
		_say("no spell in hand — modal-aim case not exercised")

	# A second fight, the way the run reaches one: the old screen goes, a new one is mounted.
	combat.queue_free()
	await get_tree().process_frame
	var combat2 := await _mount()
	_sample(combat2, "combat 2, turn 1 placement")
	get_tree().quit(0)
