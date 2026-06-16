class_name RunData
extends RefCounted

const STARTING_HEALTH := 75
const STARTING_GOLD := 100

var health: int
var max_health: int
var gold: int
var deck: Array
var act: int


static func create_new() -> RunData:
	var run := RunData.new()
	run.health     = STARTING_HEALTH
	run.max_health = STARTING_HEALTH
	run.gold       = STARTING_GOLD
	run.deck       = DeckData.get_deck(DeckData.FALLBACK_ID)
	run.act        = 1
	return run


static func from_dict(data: Dictionary) -> RunData:
	var run := RunData.new()
	run.health     = data.get("health",     STARTING_HEALTH)
	run.max_health = data.get("max_health", STARTING_HEALTH)
	run.gold       = data.get("gold",       STARTING_GOLD)
	run.deck       = data.get("deck",       [])
	run.act        = data.get("act",        1)
	return run


func to_dict() -> Dictionary:
	return {
		"health":     health,
		"max_health": max_health,
		"gold":       gold,
		"deck":       deck,
		"act":        act,
	}
