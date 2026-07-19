class_name GameAttributes
extends RefCounted

# THE registry of every tunable run/match number: each key paired with its DEFAULT value.
# A single resolver — GameData.value(key) — returns this default plus every active modifier
# for that key, so each game system reads its numbers through the exact same call and adding
# a new tunable number is one row here (no new code anywhere else).
#
# This is the global, run/match-state side of the attribute model. CARD stats (attack /
# health / cost) are deliberately NOT here: those bases live per-card in CardData and resolve
# through CardInstance.get_attribute — the symmetric, per-instance attribute holder. The same
# modifier system feeds both sides (cards via LiveEffects.bonus; globals via value()).

const DEFAULTS := {
	# Combat economy
	"mana.initial":             1,    # mana crystals on turn 1 (then +1/turn, uncapped — mana
									   # never stops growing; see Combat._begin_round)
	"mana.max":                 10,   # UNUSED by the ramp since the uncap; still referenced by
									   # the arcana upgrade tree — needs a redesign or removal
	"mana.per_turn":            0,    # flat bonus crystals EVERY turn, stacked on the ramp
	"hand.size.initial":        3,    # cards drawn into the opening hand
	"draw.per_turn":            1,    # cards drawn at the start of each round
	# Run economy
	"gold.initial":             100,  # a run's starting gold
	"king.max_health":          0,    # bonus added on top of the run King's card health
	"relic.capacity":           10,   # how many relics a run may hold at once (tunable / moddable)
	# Encounter rewards
	"reward.essence":           0,    # bonus essence granted per combat win
	"reward.king_piece_chance": 0.0,  # chance an Elite also drops a King Piece (0..1)
}


# Authored overrides on the DEFAULTS above — the Tool's 🎛 Tuning tab writes this file; an
# absent file (or key) means the code default. Registered keys only: a stray key in the JSON
# never invents a new attribute.
const OVERRIDES_PATH := "res://data/game_attributes.json"
static var _overrides: Dictionary = {}
static var _overrides_loaded := false


# Lazily loads (and caches) the authored overrides, tolerating a partial/absent/bad JSON
# (mirrors Resolver._dodge_config).
static func _override_config() -> Dictionary:
	if _overrides_loaded:
		return _overrides
	_overrides_loaded = true
	if FileAccess.file_exists(OVERRIDES_PATH):
		var file := FileAccess.open(OVERRIDES_PATH, FileAccess.READ)
		var json := JSON.new()
		if file != null and json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			for k: String in DEFAULTS:
				var v: Variant = (json.data as Dictionary).get(k)
				if v is float or v is int:
					_overrides[k] = float(v)
		else:
			push_error("GameAttributes: bad game_attributes.json — using code defaults")
	return _overrides


# The base value for a key (0 for an unregistered key, so a stray modifier still resolves).
static func default_value(key: String) -> float:
	var overrides := _override_config()
	if overrides.has(key):
		return float(overrides[key])
	return float(DEFAULTS.get(key, 0))


static func has(key: String) -> bool:
	return DEFAULTS.has(key)
