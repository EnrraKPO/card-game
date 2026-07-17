extends Node

# Headless regression runner. Run the whole suite with:
#
#   "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . res://tests/_runner.tscn
#
# Exits 0 when green, 1 on any failure (CI-able). To add a suite: create tests/test_<area>.gd
# extending TestCase (override suite_name() + run()) and list it in SUITES below.
#
# Run this after ANY change to the resolution layer (Resolver/StatMutation/EffectSystem/
# statuses) — every migration onto the Resolver is a behavior-preservation exercise, and this
# is the harness that proves it.

const SUITES: Array = [
	preload("res://tests/test_resolver.gd"),
	preload("res://tests/test_triggers.gd"),
	preload("res://tests/test_targeting.gd"),
	preload("res://tests/test_effects.gd"),
	preload("res://tests/test_statuses.gd"),
	preload("res://tests/test_interception.gd"),
	preload("res://tests/test_castling.gd"),
	preload("res://tests/test_materials.gd"),
	preload("res://tests/test_combat_side.gd"),
	preload("res://tests/test_composition_grants.gd"),
]


func _ready() -> void:
	_clean_env()
	var passed := 0
	var failed := 0
	for suite_script: GDScript in SUITES:
		var suite: TestCase = suite_script.new()
		print("── ", suite.suite_name(), " ──")
		suite.run()
		print("    %d passed, %d failed" % [suite.passed, suite.failed])
		passed += suite.passed
		failed += suite.failed
	print("")
	print("TOTAL: %d passed, %d failed — %s" % [passed, failed, "OK" if failed == 0 else "FAILURES"])
	get_tree().quit(0 if failed == 0 else 1)


# A deterministic, in-memory environment: a FRESH profile and an EMPTY modifier set — never a
# user save slot (slot profiles carry upgrade bonuses that fold into get_attribute at read
# time and skew expectations). Nothing here touches disk; select_slot is deliberately avoided
# because it writes a save file for a fresh slot.
func _clean_env() -> void:
	GameData.current_profile = ProfileData.from_dict({})
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_run = null
	GameData.current_map_state = null
	GameData.current_encounter = null
