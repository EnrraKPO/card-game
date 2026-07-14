extends Node

# Combat smoke boot (cue-population verification harness): constructs run state, mounts the
# combat scene headlessly and plays through one full Done-button round, so every cue line in
# combat.gd executes (turn start, placements, strikes, shield regen, king cues). Pixels don't
# matter here — only that no cue call errors and no unknown-id warnings print. Run:
#   Godot_console.exe --headless --path . res://tests/_combat_smoke.tscn

func _ready() -> void:
	GameData.select_slot(0)
	if GameData.current_run == null:
		GameData.start_new_run()
	if GameData.current_encounter == null:
		GameData.current_encounter = EncounterData.new()
	var combat: Node = load("res://scenes/combat.tscn").instantiate()
	add_child(combat)
	await get_tree().create_timer(3.0).timeout
	# One combat round end-to-end: strikes, deaths, shield regen, next round.
	if combat.has_method("_on_done_pressed"):
		combat.call("_on_done_pressed")
	await get_tree().create_timer(12.0).timeout
	print("D4 SMOKE DONE")
	get_tree().quit()
