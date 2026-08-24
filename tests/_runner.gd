extends Node

# Headless regression runner. Run the whole suite with:
#
#   "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . res://tests/_runner.tscn
#
# Exits 0 when green, 1 on any failure (CI-able). To add a suite: create tests/test_<area>.gd
# extending TestCase (override suite_name() + run()) and list it in SUITES below.
#
# Run this after ANY change to the resolution layer (statuses today — the single writer and
# its mutation form were nuked 2026-08-13 as cursed, and nothing has replaced them yet).

# THE TEST DOCTRINE (user ruling, 2026-08-11): only tests that validate SYSTEMS may exist,
# and only tests that validate systems that won't change may pass. Tests enforcing dead
# machinery or content boundaries are banished, and everything red is gone: the demolition
# quarantine table died with the throwaway code it was guarding (the rebuild's requirements
# live in TARGETING_DESIGN.md; each rebuild phase ships its own native suite as it lands).
# Green here means green — any failure is real breakage.
const SUITES: Array = [
	# (Suites covering the demoted combat layer retired with their subjects at the
	# A11 swap, 2026-08-23: test_locations, test_statuses, test_combat_world,
	# test_presenter, test_cascade, test_target_resolvers, test_enemy_engine,
	# test_decision_table, test_enemy_personality.)
	preload("res://tests/test_economy.gd"),
	preload("res://tests/test_forge_costs.gd"),
	preload("res://tests/test_encounter_pool.gd"),
	preload("res://tests/test_selection.gd"),
	preload("res://tests/test_core_world.gd"),
	preload("res://tests/test_write_road.gd"),
	preload("res://tests/test_rules_flow.gd"),
	preload("res://tests/test_card_roads.gd"),
	preload("res://tests/test_combat_frame.gd"),
]


func _ready() -> void:
	_clean_env()
	var passed := 0
	var failed := 0
	for suite_script: GDScript in SUITES:
		var suite: TestCase = suite_script.new()
		print("── ", suite.suite_name(), " ──")
		# The core's flow layer is coroutine-native (picks and cues await); a suite
		# exercising it awaits, and awaiting a plain suite completes on the spot.
		@warning_ignore("redundant_await")
		await suite.run()
		passed += suite.passed
		failed += suite.failed
		print("    %d passed, %d failed" % [suite.passed, suite.failed])
	print("")
	print("TOTAL: %d passed, %d failed — %s" % [passed, failed, "OK" if failed == 0 else "FAILURES"])
	get_tree().quit(0 if failed == 0 else 1)


# A deterministic, in-memory environment: a FRESH profile and an EMPTY modifier set — never a
# user save slot (slot profiles carry upgrade bonuses that fold into get_attribute at read
# time and skew expectations). Nothing here touches disk; select_slot is deliberately avoided
# because it writes a save file for a fresh slot.
func _clean_env() -> void:
	# (The dodge/crit determinism switches went with those rolls — 2026-08-13 ruling.)
	# Pin debug mode ON regardless of the local (git-ignored) debug.json, so profile seeding
	# is identical on every machine. The economy suite exercises both launch modes itself.
	DebugConfig.set_override(true)
	GameData.current_profile = ProfileData.from_dict({})
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_run = null
	GameData.current_map_state = null
	GameData.current_encounter = null
