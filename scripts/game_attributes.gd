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
	"magic_mineral.initial":    5,    # a run's starting Magic Mineral (the forge-merge resource)
	"king.max_health":          0,    # bonus added on top of the run King's card health
	"relic.capacity":           10,   # how many relics a run may hold at once (tunable / moddable)
	# Encounter rewards. Gold/mineral pay: the encounter's AUTHORED roll (per-template, may be 0)
	# PLUS the tool-driven per-node-type default below — see GameData.reward_gold/reward_mineral.
	"reward.essence":           0,    # bonus essence granted per combat win
	"reward.king_piece_chance": 0.0,  # chance an Elite also drops a King Piece (0..1)
	"reward.gold.combat":         0,  # default gold per normal-fight win (on top of the authored roll)
	"reward.gold.elite":          0,
	"reward.gold.boss":           0,
	"reward.magic_mineral.combat": 2, # default Magic Mineral per normal-fight win
	"reward.magic_mineral.elite":  3,
	"reward.magic_mineral.boss":   5,
	# Kill BOUNTIES: what a slain enemy unit pays on the spot, mid-fight (see GameData.kill_bounty).
	# The default bounty is the dead unit's mana cost times these rates — one coin flies to the
	# gold bag per gold, and the experience gauge grows by the exp. A card may author its own flat
	# bounty (CardData.bounty_gold / bounty_exp), which bypasses the rate entirely.
	"bounty.gold_per_cost":     1.0,  # gold paid per point of the dead unit's mana cost
	"bounty.exp_per_cost":      1.0,  # profile experience per point of the same
	"bounty.minimum":           1,    # floor for a rate-derived bounty (a 0-cost unit still pays)
	# Forge merge costs (Magic Mineral — see ForgeCosts.merge_cost): per-component rates count the
	# RESULT card's composition; exactly one flat applies per merge (element_only when both inputs
	# are pure-element cards, piece_op when at least one input holds a chess piece).
	"forge.cost.per_piece":     2,
	"forge.cost.per_element":   1,
	"forge.cost.element_only":  0,
	"forge.cost.piece_op":      1,
	# Shop
	"shop.magic_mineral.price": 25,   # gold price of one Magic Mineral in the shop
	# Input feel. Not run/match numbers like the rest — these are the touch gesture windows,
	# registered here so they ride the same tool/override plumbing rather than earning their
	# own config file. Read once per CardUI at _ready; no modifier ever targets them.
	"ux.hold.duration":         0.4,  # seconds a touch must be held to open the card inspector
	"ux.hold.tolerance":        44.0, # viewport px the finger may drift and still count as a hold
									   # (a drag starting inside this is provisional — see CardUI)
	"ux.move_hold.duration":    1.0,  # seconds the move button's safety hold takes to fill —
									   # the back-out window before a held press commits the move
	"ux.tooltip.delay":         0.5,  # seconds the pointer must rest on a card before its details
									   # panel opens (see CardHoverPanel). The SHIPPED number: a
									   # player may override it for themselves in Settings, and
									   # anyone who hasn't follows whatever is tuned here. 0 opens
									   # on the frame the hover latches
	"ux.consume_hold.duration": 0.9,  # seconds a consumable relic chip's hold takes to fill —
									   # shorter than the move hold (a spend has no preview to
									   # read), but still a deliberate press, never a tap
	# Animation feel. THE fluidity dial for every sequenced cue in the game (see Vfx.handoff): the
	# fraction of a cue's tail the NEXT beat is allowed to overlap. 0 = strictly one-at-a-time (each
	# cue plays to its last frame before the next starts — the old, choppy behaviour); 0.5 = the
	# next beat starts halfway through the current one, so tails cross-fade under heads and the
	# sequence never sits in dead air. Cues stay strictly ORDERED either way — this only decides
	# how much of a cue's span counts as "its moment". An individual effect overrides it with its
	# own `overlap` param (0 = atomic, my completion IS my beat).
	"vfx.overlap":              0.5,
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
