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

# TARGETING REMOVED (targeting-cleanup demolition): the pure targeting suites are deleted —
# test_targeting (the resolver kinds), test_location_socket (the at_location kind), and
# test_location_parity (the FROZEN pre-refactor distance formulas: that suite existed to
# witness that the location refactor preserved the attack-preference ordering, and per its
# own standing rule it dies when that behaviour is deliberately retired rather than being
# edited to agree). Suites that exercised payloads THROUGH targeting are trimmed or disabled
# below, each marked at the site. The rebuilt targeting authority ships with its own suites.
const SUITES: Array = [
	preload("res://tests/test_locations.gd"),
	preload("res://tests/test_resolver.gd"),
	preload("res://tests/test_triggers.gd"),
	preload("res://tests/test_effects.gd"),
	preload("res://tests/test_statuses.gd"),
	preload("res://tests/test_interception.gd"),
	preload("res://tests/test_castling.gd"),
	preload("res://tests/test_materials.gd"),
	preload("res://tests/test_combat_side.gd"),
	preload("res://tests/test_composition_grants.gd"),
	preload("res://tests/test_dodge.gd"),
	preload("res://tests/test_crit.gd"),
	preload("res://tests/test_economy.gd"),
	preload("res://tests/test_spawn_strikes.gd"),
	preload("res://tests/test_forge_costs.gd"),
	preload("res://tests/test_encounter_pool.gd"),
	preload("res://tests/test_decision_table.gd"),
	preload("res://tests/test_enemy_engine.gd"),
	preload("res://tests/test_enemy_personality.gd"),
	preload("res://tests/test_selection.gd"),
	preload("res://tests/test_combat_world.gd"),
	preload("res://tests/test_presenter.gd"),
	preload("res://tests/test_cascade.gd"),
	preload("res://tests/test_slot_layer.gd"),
	preload("res://tests/test_burning.gd"),
]


# ── TARGETING DEMOLITION QUARANTINE ────────────────────────────────────────────────────
# While targeting is demolished (branch targeting-cleanup), every check that asserts an
# effect LANDING or a strike FINDING someone fails by design — resolution is inert. Those
# checks are the REBUILD'S SPECIFICATION and regression net, so they are neither deleted nor
# silenced: each suite below carries its expected failure count, the runner reports them as
# quarantined, and the exit code stays green unless a suite fails MORE than expected (new
# breakage) or LESS (tighten the table). The rebuilt targeting authority's exit criterion is
# driving every number here to zero and deleting this table.
const QUARANTINE := {
	"Trigger resolvers": 9,
	"Effects & Interception": 16,
	"Statuses": 10,
	"Interception": 3,
	"Castling & abilities": 7,
	"Materials & merge": 1,
	"Combat sides": 8,
	"CompositionGrants": 12,
	"Dodge": 2,
	"Crit": 5,
	"Spawn payload & multi-strike": 1,
	"Enemy engine": 12,
	"Combat world": 4,
	"Combat cascade": 1,
	"Slot layer": 7,
	"Burning ground": 23,
}


func _ready() -> void:
	_clean_env()
	var passed := 0
	var failed := 0
	var quarantined := 0
	var unexpected := 0
	for suite_script: GDScript in SUITES:
		var suite: TestCase = suite_script.new()
		print("── ", suite.suite_name(), " ──")
		suite.run()
		var expected: int = int(QUARANTINE.get(suite.suite_name(), 0))
		passed += suite.passed
		failed += suite.failed
		if suite.failed == expected:
			quarantined += expected
			print("    %d passed, %d failed%s" % [suite.passed, suite.failed,
					"" if expected == 0 else " (all quarantined — expected while targeting is demolished)"])
		else:
			unexpected += 1
			print("    %d passed, %d failed — EXPECTED %d: %s" % [suite.passed, suite.failed,
					expected, "NEW BREAKAGE" if suite.failed > expected else "tighten the quarantine table"])
	print("")
	print("TOTAL: %d passed, %d failed (%d quarantined by the targeting demolition) — %s"
			% [passed, failed, quarantined, "OK" if unexpected == 0 else "FAILURES"])
	get_tree().quit(0 if unexpected == 0 else 1)


# A deterministic, in-memory environment: a FRESH profile and an EMPTY modifier set — never a
# user save slot (slot profiles carry upgrade bonuses that fold into get_attribute at read
# time and skew expectations). Nothing here touches disk; select_slot is deliberately avoided
# because it writes a save file for a fresh slot.
func _clean_env() -> void:
	# Dodge and crit are the non-authored sources of RNG in the Resolver; off by default here so
	# the damage-math suites are deterministic. Each feature's suite re-enables its own.
	Resolver.dodge_enabled = false
	Resolver.crit_enabled = false
	# Pin debug mode ON regardless of the local (git-ignored) debug.json, so profile seeding
	# is identical on every machine. The economy suite exercises both launch modes itself.
	DebugConfig.set_override(true)
	GameData.current_profile = ProfileData.from_dict({})
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_run = null
	GameData.current_map_state = null
	GameData.current_encounter = null
