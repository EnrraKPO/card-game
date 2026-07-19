class_name EconomyConfig
extends RefCounted

# The data-driven starting economy — what a fresh profile/run begins with. Authored by the
# Tool (🎛 Tuning ▸ 💰 Economy) into data/economy.json; an absent file (or key) falls back
# to the defaults below, which reproduce the historical dev seed exactly.
#
# Two bags:
#   • initial — the SHIPPING economy: resources every fresh profile starts with.
#   • debug   — dev overrides: while `enabled` AND the launch is a debug launch
#               (DebugConfig.enabled(), the git-ignored debug.json), this bag REPLACES
#               `initial` wholesale (materials + upgrade points), and its `gold` /
#               `magic_mineral` (when >= 0) pin the run's starting purse / mineral stock
#               to a fixed amount. -1 means "no override" — the value keeps resolving
#               through GameData.value("gold.initial" / "magic_mineral.initial"), so
#               attribute tuning and upgrade modifiers stay observable while the debug
#               bag is on.
#
# Materials are keyed by Materials ids: bare element = essence, "<element>_stone",
# "<chesspiece>_piece", and "magic_mineral" (Materials.MAGIC_MINERAL).

const PATH := "res://data/economy.json"

static var _cfg: Dictionary = {}
static var _loaded := false


# The historical TEMP dev seed (formerly hardcoded in ProfileData.create_default), now as
# the default DEBUG bag: enough King Pieces to forge every King (21), a stock of every
# stone, chess-piece tokens to mint cards with, and spendable upgrade points. The shipping
# (initial) economy stays empty until it is deliberately designed.
static func _defaults() -> Dictionary:
	var debug_materials := {Materials.piece_id("king"): 21}
	for piece: String in Materials.PIECES:
		if piece != "king":
			debug_materials[Materials.piece_id(piece)] = 10
	for element: String in Materials.ELEMENTS:
		debug_materials[Materials.stone_id(element)] = 10
	return {
		"initial": {"materials": {}, "upgrade_points": 0},
		"debug": {"enabled": true, "gold": -1, "magic_mineral": -1,
			"materials": debug_materials, "upgrade_points": 12},
	}


# Lazily loads (and caches) the authored config, tolerating a partial/absent/bad JSON
# (mirrors GameAttributes._override_config).
static func _config() -> Dictionary:
	if _loaded:
		return _cfg
	_loaded = true
	_cfg = _defaults()
	if FileAccess.file_exists(PATH):
		var file := FileAccess.open(PATH, FileAccess.READ)
		var json := JSON.new()
		if file != null and json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			for bag: String in ["initial", "debug"]:
				var src: Variant = (json.data as Dictionary).get(bag)
				if src is Dictionary:
					_merge_bag(_cfg[bag] as Dictionary, src as Dictionary)
		else:
			push_error("EconomyConfig: bad economy.json — using defaults")
	return _cfg


# Overlays an authored bag onto its default. An authored materials dict is taken WHOLESALE
# (the tool writes complete bags — authored-empty must mean empty, not "keep the seed"),
# restricted to known ids and positive counts; scalars replace when well-typed.
static func _merge_bag(dst: Dictionary, src: Dictionary) -> void:
	if src.get("materials") is Dictionary:
		var known := Materials.all_ids()
		var mats: Dictionary = {}
		for id: String in (src["materials"] as Dictionary):
			var v: Variant = (src["materials"] as Dictionary)[id]
			if id in known and (v is float or v is int) and int(v) > 0:
				mats[id] = int(v)
		dst["materials"] = mats
	var up: Variant = src.get("upgrade_points")
	if up is float or up is int:
		dst["upgrade_points"] = maxi(0, int(up))
	if src.get("enabled") is bool:
		dst["enabled"] = src["enabled"]
	var gold: Variant = src.get("gold")
	if gold is float or gold is int:
		dst["gold"] = maxi(-1, int(gold))
	var mineral: Variant = src.get("magic_mineral")
	if mineral is float or mineral is int:
		dst["magic_mineral"] = maxi(-1, int(mineral))


# Injects a config directly, bypassing the JSON (the regression harness uses this to
# exercise the bag logic deterministically). Unset keys keep their defaults. Pass {} to
# force a reload from disk on the next read (mirrors Resolver.set_dodge_tuning).
static func set_config(cfg: Dictionary) -> void:
	if cfg.is_empty():
		_cfg = {}
		_loaded = false
		return
	_cfg = _defaults()
	for bag: String in ["initial", "debug"]:
		if cfg.get(bag) is Dictionary:
			_merge_bag(_cfg[bag] as Dictionary, cfg[bag] as Dictionary)
	_loaded = true


# The debug bag applies only when this LAUNCH is debug (local debug.json) AND the bag
# itself is enabled (authored in the Tool) — a release-mode launch always plays the
# shipping economy, whatever the tool authored.
static func debug_enabled() -> bool:
	return DebugConfig.enabled() and bool((_config()["debug"] as Dictionary).get("enabled", false))


# The active bag: debug (while enabled) or the shipping initial economy.
static func _active() -> Dictionary:
	var key := "debug" if debug_enabled() else "initial"
	return _config()[key] as Dictionary


# What a fresh profile's material bag starts with (id → count).
static func starting_materials() -> Dictionary:
	return (_active().get("materials", {}) as Dictionary).duplicate()


static func starting_upgrade_points() -> int:
	return int(_active().get("upgrade_points", 0))


# The debug starting-gold override, or -1 for none (normal gold.initial resolution).
static func gold_override() -> int:
	if not debug_enabled():
		return -1
	return int((_config()["debug"] as Dictionary).get("gold", -1))


# The debug starting-Magic-Mineral override, or -1 for none (normal magic_mineral.initial
# resolution). The mineral is RUN-scoped (RunData.magic_mineral), not a profile material.
static func mineral_override() -> int:
	if not debug_enabled():
		return -1
	return int((_config()["debug"] as Dictionary).get("magic_mineral", -1))
