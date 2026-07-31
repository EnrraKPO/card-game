extends Node
# Throwaway probe for the combat debug-visibility work: boots a REAL fight, lets the CPU
# take its turn, then exercises both new debug affordances — dumps the combat log and opens
# the damage-share overlay — and screenshots the result.
#   godot --path . res://dev/_debugvis_probe.tscn        (NOT --headless: it renders)

const OUT := "res://dev/_debugvis_out.png"
const RES := Vector2i(1920, 1080)


func _ready() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()
	GameData.current_run.relics.append_array(["battle_standard", "iron_aegis"])

	# A real encounter, the way the Combat Gym launches one — otherwise the CPU stands there
	# with an empty hand and the engine never makes a decision worth logging.
	var tpl: EncounterTemplateData = EncounterTemplateData.all()[0]
	var erng := RandomNumberGenerator.new()
	erng.seed = 4242
	var enc := tpl.instantiate(erng, EncounterTemplateData.power_for_depth(3))
	enc.practice = true
	GameData.current_encounter = enc

	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.auto_start = false
	sv.add_child(shell)
	shell.mount("res://scenes/combat.tscn")
	await get_tree().process_frame

	# Let the opening round play out: the CPU's whole turn, timers and all.
	await get_tree().create_timer(6.0).timeout

	var combat: Node = null
	for n: Node in sv.find_children("*", "Control", true, false):
		if n.has_method("_toggle_damage_inspector"):
			combat = n
			break
	if combat == null:
		print("PROBE: combat screen not found")
		get_tree().quit()
		return

	print("PROBE: seed = ", CombatRng.seed_value(), "  recording = ", CombatLog.recording())

	# 1. The log — dump it and show what it captured.
	var path: String = CombatLog.dump()
	print("PROBE: log written to ", path)
	print("──────── LOG ────────")
	print(CombatLog.text())
	print("─────── END LOG ───────")

	# 2. The overlay — open it the way the button does, then shoot it.
	combat.call("_toggle_damage_inspector")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	var img := sv.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: shot saved to ", OUT)
	get_tree().quit()
