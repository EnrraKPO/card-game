class_name RunData
extends RefCounted

const STARTING_GOLD := 100

# The King is the player's run-long avatar and the only loss condition: when its
# health hits 0 in a fight, the run is over. The King unit itself is rebuilt fresh
# each combat (CombatBoard.place_kings), so the only thing we persist between fights
# is how wounded it is — accumulated, unhealed damage. Current health is never
# stored; it's just (max health - king_damage), computed when a fight starts.
var king_damage: int = 0
var king_id: String = "king"   # which King card this run is played with (from the profile)
var gold: int
var deck: Array   # Array[DeckCard] — each entry carries its own permanent mods
var act: int
var charms: Array = []   # owned, unapplied charm ids (inventory); applied in the forge


# Seeds a fresh run from the profile's chosen King and starting deck. Falls back to
# the default King + starter deck when no profile is supplied (e.g. tooling/tests).
static func create_new(profile: ProfileData = null) -> RunData:
	var run := RunData.new()
	run.king_damage = 0
	run.gold        = STARTING_GOLD
	if profile != null:
		run.king_id = profile.selected_king
		run.deck    = _deck_from_variants(profile.starting_deck)
	else:
		run.king_id = "king"
		run.deck    = _deck_from_variants(DeckData.get_deck(DeckData.FALLBACK_ID))
	run.act = 1
	# Starting charm inventory — generous for now so the forge/shop charm flow is testable;
	# trim once charms are properly earned through rewards.
	run.charms = ["sharpened", "sharpened", "vampiric", "warded", "rallying", "thorned"]
	return run


static func from_dict(data: Dictionary) -> RunData:
	var run := RunData.new()
	if data.has("king_damage"):
		run.king_damage = data.get("king_damage", 0)
	elif data.has("health") and data.has("max_health"):
		# Migrate legacy saves that stored absolute current/max health.
		run.king_damage = maxi(0, int(data["max_health"]) - int(data["health"]))
	run.king_id = data.get("king_id", "king")
	run.gold = data.get("gold", STARTING_GOLD)
	run.deck = _deck_from_variants(data.get("deck", []))
	run.act  = data.get("act",  1)
	run.charms = data.get("charms", [])
	return run


func to_dict() -> Dictionary:
	var deck_data: Array = []
	for dc: DeckCard in deck:
		deck_data.append(dc.to_dict())
	return {
		"king_damage": king_damage,
		"king_id":     king_id,
		"gold":        gold,
		"deck":        deck_data,
		"act":         act,
		"charms":      charms,
	}


# Normalises a raw deck list (DeckData ids, or saved dicts, or legacy bare strings)
# into Array[DeckCard].
static func _deck_from_variants(raw: Array) -> Array:
	var out: Array = []
	for v in raw:
		out.append(DeckCard.from_variant(v))
	return out


# The King's maximum health — its card stat is the single source of truth. (When
# per-run max-health upgrades exist, fold a stored bonus in here.)
func king_max_health() -> int:
	var king := CardData.get_card(king_id)
	return king.health if king != null else 1


# The King's health entering a fight: full max, minus the damage carried over.
func king_health() -> int:
	return maxi(0, king_max_health() - king_damage)
