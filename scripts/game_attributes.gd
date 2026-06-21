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
# modifier system feeds both sides (cards via ModifierSet.card_bonus; globals via value()).

const DEFAULTS := {
	# Combat economy
	"mana.initial":             1,    # mana crystals on turn 1 (then +1/turn up to mana.max)
	"mana.max":                 10,   # the mana ceiling the per-turn ramp climbs toward
	"mana.per_turn":            0,    # flat bonus crystals EVERY turn, stacked on top of the cap
	"hand.size.initial":        4,    # cards drawn into the opening hand
	"draw.per_turn":            1,    # cards drawn at the start of each round
	# Run economy
	"gold.initial":             100,  # a run's starting gold
	"king.max_health":          0,    # bonus added on top of the run King's card health
	# Encounter rewards
	"reward.essence":           0,    # bonus essence granted per combat win
	"reward.king_piece_chance": 0.0,  # chance an Elite also drops a King Piece (0..1)
}


# The base value for a key (0 for an unregistered key, so a stray modifier still resolves).
static func default_value(key: String) -> float:
	return float(DEFAULTS.get(key, 0))


static func has(key: String) -> bool:
	return DEFAULTS.has(key)
