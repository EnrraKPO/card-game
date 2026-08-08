extends Node
# Throwaway: does spending a consumable relic actually REMOVE it from the run? Boots a real
# combat and SPENDS the bomb the way a player does — touch the chip, hold past the fill, release —
# in two cases: an ordinary use, and a use that KILLS THE ENEMY KING (which ends the fight and
# tears the combat screen down mid-animation). Results are written to a file, because the winning
# case changes scene and takes this probe's own coroutine with it.
#   godot --path . res://dev/_consume_spend_probe.tscn        (kill_king = false / true below)

const KILL_KING := false
const OUT := "user://consume_probe.txt"


func _say(line: String) -> void:
	print(line)
	var f := FileAccess.open(OUT, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(OUT, FileAccess.WRITE)
	f.seek_end()
	f.store_line(line)
	f.close()


func _touch(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.pressed = pressed
	ev.position = pos
	Input.parse_input_event(ev)


func _ready() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT))
	await get_tree().process_frame
	GameData.current_slot = 0
	GameData.start_new_run()
	_say("relics at start: %s  (kill_king=%s)" % [GameData.current_run.relics, KILL_KING])

	var combat: Control = load("res://scenes/combat.tscn").instantiate()
	add_child(combat)
	for i in 20:
		await get_tree().process_frame

	# Fodder the bomb kills, and optionally an enemy king it finishes off.
	var board = combat.get("_board")
	for c in 3:
		var foe := CardInstance.from_data(CardData.get_card("pawn"))
		foe.owner = 1
		board.place_enemy_card(foe, BoardLocation.at(1, 1, c))
	if KILL_KING:
		var eking = board.get_enemy_king()
		eking.current_health = 1
		eking.shield_spent = 99
	for i in 10:
		await get_tree().process_frame

	var tray = combat.get("_relic_tray")
	var chip: Control = null
	for c in tray.get_children():
		if c is ConsumableChip:
			chip = c
	var at: Vector2 = chip.get_global_rect().get_center()
	_say("chip at %s (found=%s)" % [at, chip != null])

	_touch(at, true)
	var held := 0.0
	while held < GameData.value_f("ux.consume_hold.duration") + 0.4:
		held += get_process_delta_time()
		await get_tree().process_frame
	_touch(at, false)
	# One frame after the commit: has the relic already been spent, before any animation?
	await get_tree().process_frame
	_say("relics right after commit: %s" % [GameData.current_run.relics])

	for i in 300:
		await get_tree().process_frame
	_say("relics after the animation: %s" % [GameData.current_run.relics])
	get_tree().quit(0)
