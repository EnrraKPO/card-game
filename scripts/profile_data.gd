class_name ProfileData
extends RefCounted

# Profile-scoped meta-progression that outlives any single run — a sibling to
# RunData/MapState, but persisted ONCE per profile (a "profile" save section), not
# per run slot. A new run draws its starting King and deck from here, and permanent
# unlocks accumulate here across runs. Surfaced by the "game world" hub
# (game_world.gd). This is the load-bearing layer for the roguelike meta loop;
# content panels (king select, deck editing, unlock shop) build on top of it.

const STARTING_KING := "king"

var unlocked_kings: Array = []   # Array[String]: king card ids the player may run with
var selected_king: String = STARTING_KING
var starting_deck: Array = []    # Array[String]: card ids a fresh run begins with
var renown: int = 0              # meta-currency earned from runs, spent on permanent unlocks


static func create_default() -> ProfileData:
	var p := ProfileData.new()
	p.unlocked_kings = [STARTING_KING]
	p.selected_king  = STARTING_KING
	p.starting_deck  = DeckData.get_deck(DeckData.FALLBACK_ID)
	p.renown         = 0
	return p


static func from_dict(data: Dictionary) -> ProfileData:
	if data.is_empty():
		return create_default()
	var p := ProfileData.new()
	p.unlocked_kings = data.get("unlocked_kings", [STARTING_KING])
	p.selected_king  = data.get("selected_king", STARTING_KING)
	p.starting_deck  = data.get("starting_deck", DeckData.get_deck(DeckData.FALLBACK_ID))
	p.renown         = int(data.get("renown", 0))
	return p


func to_dict() -> Dictionary:
	return {
		"unlocked_kings": unlocked_kings,
		"selected_king":  selected_king,
		"starting_deck":  starting_deck,
		"renown":         renown,
	}
