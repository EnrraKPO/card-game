extends TestCase

# The data-driven starting economy (EconomyConfig / data/economy.json): the shipping
# `initial` bag vs the `debug` override bag (enabled ⇒ replaces initial wholesale; its
# gold ≥ 0 pins the run purse, -1 keeps the normal gold.initial resolution). Defaults must
# reproduce the historical dev seed exactly. Configs are injected via set_config — the
# harness never reads the authored data/economy.json.


func suite_name() -> String:
	return "Economy"


func run() -> void:
	_vocabulary()
	_defaults()
	_initial_bag()
	_debug_bag()
	_launch_gate()
	_sanitizing()
	EconomyConfig.set_config({})        # restore disk-backed config for whatever runs next
	DebugConfig.set_override(true)      # restore the runner's pinned debug mode


# The debug bag applies only in a DEBUG LAUNCH (DebugConfig / the git-ignored debug.json):
# a release-mode launch plays the shipping economy no matter what the tool authored.
func _launch_gate() -> void:
	EconomyConfig.set_config({
		"initial": {"materials": {"fire": 5}, "upgrade_points": 2},
		"debug": {"enabled": true, "gold": 5000, "materials": {"water_stone": 7}, "upgrade_points": 3},
	})
	DebugConfig.set_override(false)
	check(not EconomyConfig.debug_enabled(), "release launch: debug economy is off even when authored on")
	var mats := EconomyConfig.starting_materials()
	check_eq(int(mats.get("fire", 0)), 5, "release launch: the initial bag applies")
	check_eq(int(mats.get("water_stone", 0)), 0, "release launch: the debug bag contributes nothing")
	check_eq(EconomyConfig.gold_override(), -1, "release launch: no gold pin")
	check_eq(EconomyConfig.starting_upgrade_points(), 2, "release launch: initial upgrade points")
	DebugConfig.set_override(true)
	check_eq(EconomyConfig.gold_override(), 5000, "debug launch: the same config pins gold again")


func _vocabulary() -> void:
	check_eq(Materials.category("magic_mineral"), "mineral", "magic_mineral is its own category")
	check_eq(Materials.display_name("magic_mineral"), "Magic Mineral", "magic mineral display name")
	check_eq(Materials.category("fire_stone"), "stone", "stones keep their category")
	var ids := Materials.all_ids()
	check_eq(ids.size(), 19, "vocabulary = 6 essences + 6 stones + 6 pieces + magic mineral")
	check("magic_mineral" in ids and "fire" in ids and "light_stone" in ids and "king_piece" in ids,
			"all_ids spans every category")


func _defaults() -> void:
	EconomyConfig.set_config({})
	# The regression environment has no authored data/economy.json expectations — inject the
	# code defaults explicitly so this suite is immune to a locally authored file.
	EconomyConfig.set_config({"initial": {}, "debug": {}})
	check(EconomyConfig.debug_enabled(), "debug bag is enabled by default (the dev seed)")
	check_eq(EconomyConfig.gold_override(), -1, "no gold override by default")
	var mats := EconomyConfig.starting_materials()
	check_eq(int(mats.get("king_piece", 0)), 21, "seed: 21 King Pieces")
	check_eq(int(mats.get("pawn_piece", 0)), 10, "seed: 10 of each other piece token")
	check_eq(int(mats.get("fire_stone", 0)), 10, "seed: 10 of each elemental stone")
	check_eq(int(mats.get("fire", 0)), 0, "seed grants no essences")
	check_eq(int(mats.get("magic_mineral", 0)), 0, "seed grants no magic mineral")
	check_eq(EconomyConfig.starting_upgrade_points(), 12, "seed: 12 upgrade points")
	var p := ProfileData.create_default()
	check_eq(p.materials.count("king_piece"), 21, "a fresh profile receives the active bag")
	check_eq(p.upgrade_points, 12, "a fresh profile receives the active upgrade points")


func _initial_bag() -> void:
	EconomyConfig.set_config({
		"initial": {"materials": {"fire": 5, "magic_mineral": 3}, "upgrade_points": 2},
		"debug": {"enabled": false, "gold": 5000, "materials": {"water_stone": 7}, "upgrade_points": 9},
	})
	check(not EconomyConfig.debug_enabled(), "debug bag can be disabled")
	var mats := EconomyConfig.starting_materials()
	check_eq(int(mats.get("fire", 0)), 5, "initial bag applies while debug is off")
	check_eq(int(mats.get("magic_mineral", 0)), 3, "magic mineral is grantable")
	check_eq(int(mats.get("water_stone", 0)), 0, "the disabled debug bag contributes nothing")
	check_eq(EconomyConfig.starting_upgrade_points(), 2, "initial upgrade points apply")
	check_eq(EconomyConfig.gold_override(), -1, "a disabled debug bag never overrides gold")
	var run := RunData.create_new()
	check_eq(run.gold, GameData.value("gold.initial"), "run gold resolves normally without an override")


func _debug_bag() -> void:
	EconomyConfig.set_config({
		"initial": {"materials": {"fire": 5}, "upgrade_points": 2},
		"debug": {"enabled": true, "gold": 5000, "materials": {"water_stone": 7}, "upgrade_points": 3},
	})
	var mats := EconomyConfig.starting_materials()
	check_eq(int(mats.get("water_stone", 0)), 7, "an enabled debug bag REPLACES the initial bag")
	check_eq(int(mats.get("fire", 0)), 0, "…the initial materials do not leak through")
	check_eq(EconomyConfig.starting_upgrade_points(), 3, "debug upgrade points apply")
	check_eq(EconomyConfig.gold_override(), 5000, "debug gold pins the purse")
	check_eq(RunData.create_new().gold, 5000, "a fresh run starts at the pinned gold")
	var p := ProfileData.create_default()
	check_eq(p.materials.count("water_stone"), 7, "a fresh profile receives the debug bag")
	check_eq(p.materials.count("king_piece"), 0, "…and none of the default seed")

	EconomyConfig.set_config({
		"initial": {}, "debug": {"enabled": true, "gold": -1, "materials": {}, "upgrade_points": 0}})
	check_eq(EconomyConfig.gold_override(), -1, "debug gold -1 = no override even while enabled")
	check_eq(RunData.create_new().gold, GameData.value("gold.initial"),
			"…so the run purse keeps riding gold.initial")


func _sanitizing() -> void:
	EconomyConfig.set_config({
		"initial": {"materials": {"bogus_thing": 99, "fire": -4, "water": 2.7, "earth": 6}},
		"debug": {"enabled": false},
	})
	var mats := EconomyConfig.starting_materials()
	check(not mats.has("bogus_thing"), "unknown material ids are dropped")
	check(not mats.has("fire"), "negative counts are dropped")
	check_eq(int(mats.get("water", 0)), 2, "float counts are truncated to ints")
	check_eq(int(mats.get("earth", 0)), 6, "well-formed counts pass")
