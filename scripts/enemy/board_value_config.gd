class_name BoardValueConfig
extends RefCounted

# The authored exchange rates behind the "total board value" criterion (the retired scorer's
# BoardValue): what one point of each stat — and one ability / triggered effect / live
# effect — is worth in the eval's common currency. EVERY number here is tool-authorable
# by design: authored into data/board_value.json, absent file (or key) falls back to the
# defaults below. Mirrors EconomyConfig's load pattern.
#
# THE PAYLOAD/CARRIER PRICING: health and shield are INSTRUMENTAL, not terminal — their
# value exists to absorb damage, and that absorption is already priced by the valuation
# pass's persistence stage (a bigger pool raises persistence, which preserves the value of
# every OTHER stat). Pricing the pool in raw value too would double-count it: health would
# inflate its own term AND everyone else's. So raw value prices what a unit DOES (attack,
# abilities, effects); the pool prices how long it keeps doing it, through persistence
# alone. Health/shield rates are MINIMAL rather than zero — a bigger frame still breaks
# ties, and no unit degenerates to worth-nothing inside the min-max normalization. A tank
# (big pool, tiny kit) thereby prices as a cheap body wrapped around a big absorber —
# "meant to be spent" falls out of the arithmetic, with no role-tag machinery. The parked
# board-value quirk's unit_value reads the shared "health"/"missing_health" rates, so its
# arithmetic moves with this table.
#
# ⚠ Do NOT make spent health negative: badly wounded units then score NEGATIVE total
# value, and a unit worth less than nothing is one the engine would rather see dead.
# Both terms stay positive.
#
# Attack is valued on the unit's real output. All defaults PROVISIONAL
# until playtested — and all of them are tool-authorable (Tool ▸ 🎛 Tuning ▸ ♟ Board value).

const PATH := "res://data/board_value.json"

static var _cfg: Dictionary = {}
static var _loaded := false


static func _defaults() -> Dictionary:
	return {
		"stat_rates": {
			"attack": 1.0,          # per point of attack — the payload's yardstick
			"health": 0.1,          # MINIMAL: the pool is priced by persistence
			"missing_health": 0.1,  # per point of max − current (parked quirk's split only)
			"shield": 0.2,          # minimal like health; regeneration shows up as persistence
			"speed": 0.5,           # half value (also instrumental via dodge/crit/first-strike
			                        # flows — left as-is deliberately, one dial at a time)
		},
		"ability_default": 2.0,     # any activated ability, unless priced by id below
		"ability_values": {},       # per-ability-id overrides, e.g. {"heal": 3.0}
		# (triggered_default / live_default — the per-effect-category prices — died with
		# the effect layer, 2026-08-11; the rebuilt structures re-enter category pricing
		# with their own keys.)
		# ── the valuation pass (retired) ──
		# THE persistence dial, 0..1: how much a unit's likelihood of dying this turn
		# discounts its raw worth (value = raw × lerp(1, persistence, this)). 0 = a dying
		# queen is still a queen; 1 = a doomed unit is worth nearly nothing. Swept window:
		# below ~0.6 preservation never outbids growth (heals lose to placements even on
		# a precious dying unit), around 0.8+ the stock king starts walking to the front
		# line unprompted.
		"persistence_weight": 0.65,
		# ⚠ PARKED: the valuation pass does not consult role tags — roles unfold
		# naturally from stats (a tank IS a big pool around a small kit; nothing needs
		# the word "tank"), and protecting high-value targets is a FUTURE eval's job, not
		# a price. The key still parses (authored JSONs stay valid, role_value() still
		# answers) but raw_unit_value never reads it.
		"role_values": {},
		# Arbitrary per-card enhancers, keyed by card id — the valuation pass's open
		# hook: "this specific unit is worth 3 more than its sheet says".
		"unit_values": {},
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
	for key: String in ["ability_default", "persistence_weight"]:
		var v: Variant = src.get(key)
		if v is float or v is int:
			dst[key] = float(v)
	for map_key: String in ["ability_values", "role_values", "unit_values"]:
		if src.get(map_key) is Dictionary:
			var vals: Dictionary = {}
			for id: String in (src[map_key] as Dictionary):
				var v: Variant = (src[map_key] as Dictionary)[id]
				if v is float or v is int:
					vals[id] = float(v)
			dst[map_key] = vals


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


# Whether this ability has an authored price of its own (as opposed to falling to the blanket
# default). A personality's blanket rate must not silently override a statement someone made
# about ONE ability — see EnemyPersonality.ability_value, which asks this.
static func has_ability_price(id: String) -> bool:
	return (_config()["ability_values"] as Dictionary).has(id)


static func ability_value(id: String) -> float:
	var vals: Dictionary = _config()["ability_values"]
	if vals.has(id):
		return float(vals[id])
	return float(_config()["ability_default"])


# ── The valuation pass's own knobs (retired with the scorer) ───────────────────────────

# The persistence dial, clamped to its meaningful range (see _defaults).
static func persistence_weight() -> float:
	return clampf(float(_config()["persistence_weight"]), 0.0, 1.0)


# The role key a unit's flat bonus is filed under: the implicit "captain" tag for kings,
# the unit's own tag, else "default" (untagged). One resolution, shared with the
# personality layer so both tables speak the same key.


static func unit_bonus(card_id: String) -> float:
	return float((_config()["unit_values"] as Dictionary).get(card_id, 0.0))
