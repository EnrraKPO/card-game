class_name BoardValueConfig
extends RefCounted

# The authored exchange rates behind the "total board value" criterion (BoardScoring.
# BoardValue): what one point of each stat — and one ability / triggered effect / live
# effect — is worth in the eval's common currency. EVERY number here is tool-authorable
# by design (user mandate 2026-07-29): authored into data/board_value.json, absent file
# (or key) falls back to the defaults below. Mirrors EconomyConfig's load pattern.
#
# The default biases are the user's: shield counts DOUBLE (it regenerates every round),
# speed counts HALF, and health is split — the health a unit still HAS counts full, the
# health it has SPENT counts 0.1. Both count, because a unit's max health is part of what
# it is worth: a 4/5 carrying one wound is worth slightly more than an untouched 4/4
# (4.1 vs 4.0 — the user's own test case). A spent point is not a penalty; it just earns
# far less than a point still held, which also makes healing worth ~0.9 per point,
# a shade under a point of attack.
#
# ⚠ Do NOT make spent health negative. It was briefly built that way (−0.5) on a misread
# of "negative bias", which inverted the 4/5-vs-4/4 case AND let badly wounded units score
# NEGATIVE total value — a unit worth less than nothing is one the engine would rather see
# dead. Both terms stay positive.
#
# Attack is valued on the unit's real output, attack × strikes. All defaults PROVISIONAL
# until playtested — and all of them are tool-authorable (Tool ▸ 🎛 Tuning ▸ ♟ Board value).

const PATH := "res://data/board_value.json"

static var _cfg: Dictionary = {}
static var _loaded := false


static func _defaults() -> Dictionary:
	return {
		"stat_rates": {
			"attack": 1.0,          # per point of attack × strikes
			"health": 1.0,          # per point of CURRENT health
			"missing_health": 0.1,  # per point of max − current: spent health, worth little
			"shield": 2.0,          # regenerates each round — worth double
			"speed": 0.5,           # half value
		},
		"ability_default": 2.0,     # any activated ability, unless priced by id below
		"ability_values": {},       # per-ability-id overrides, e.g. {"heal": 3.0}
		"triggered_default": 1.5,   # per event-driven effect (Kind TRIGGERED/CUSTOM)
		"live_default": 1.5,        # per standing effect (Kind MODIFIER/INTERCEPTOR)
	}


# Lazily loads (and caches) the authored config, tolerating a partial/absent/bad JSON.
static func _config() -> Dictionary:
	if _loaded:
		return _cfg
	_loaded = true
	_cfg = _defaults()
	if FileAccess.file_exists(PATH):
		var file := FileAccess.open(PATH, FileAccess.READ)
		var json := JSON.new()
		if file != null and json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			_merge(_cfg, json.data as Dictionary)
		else:
			push_error("BoardValueConfig: bad board_value.json — using defaults")
	return _cfg


# Overlays authored entries onto the defaults: known scalar keys replace when numeric;
# stat_rates merges per-key (an authored file may price only what it cares about);
# ability_values is taken wholesale, numeric entries only.
static func _merge(dst: Dictionary, src: Dictionary) -> void:
	if src.get("stat_rates") is Dictionary:
		var rates: Dictionary = dst["stat_rates"]
		for key: String in (src["stat_rates"] as Dictionary):
			var v: Variant = (src["stat_rates"] as Dictionary)[key]
			if rates.has(key) and (v is float or v is int):
				rates[key] = float(v)
	for key: String in ["ability_default", "triggered_default", "live_default"]:
		var v: Variant = src.get(key)
		if v is float or v is int:
			dst[key] = float(v)
	if src.get("ability_values") is Dictionary:
		var vals: Dictionary = {}
		for id: String in (src["ability_values"] as Dictionary):
			var v: Variant = (src["ability_values"] as Dictionary)[id]
			if v is float or v is int:
				vals[id] = float(v)
		dst["ability_values"] = vals


# Injects a config directly, bypassing the JSON (tests). Pass {} to force a reload from
# disk on the next read.
static func set_config(cfg: Dictionary) -> void:
	if cfg.is_empty():
		_cfg = {}
		_loaded = false
		return
	_cfg = _defaults()
	_merge(_cfg, cfg)
	_loaded = true


static func stat_rate(key: String) -> float:
	return float((_config()["stat_rates"] as Dictionary).get(key, 0.0))


static func ability_value(id: String) -> float:
	var vals: Dictionary = _config()["ability_values"]
	if vals.has(id):
		return float(vals[id])
	return float(_config()["ability_default"])


static func triggered_value() -> float:
	return float(_config()["triggered_default"])


static func live_value() -> float:
	return float(_config()["live_default"])
