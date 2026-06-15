class_name RunData
extends RefCounted

const STARTING_HEALTH := 75
const STARTING_GOLD := 100

var health: int
var max_health: int
var gold: int
var deck: Array
var act: int
var map_seed: int
var current_node_id: int
var visited_nodes: Array


const STARTER_DECK: Array = [
	"king",
	"strike",    "strike",    "strike",
	"defender",  "defender",  "defender",
	"swift",     "swift",     "swift",
	"warrior",   "warrior",   "warrior",
	"archer",    "archer",    "archer",
	"berserker", "berserker",
	"commander",
	"plague_doc","plague_doc",
	"martyr",
	"vampire",   "vampire",
	"brute",
	"assassin",  "assassin",
]

static func create_new() -> RunData:
	var run := RunData.new()
	run.health = STARTING_HEALTH
	run.max_health = STARTING_HEALTH
	run.gold = STARTING_GOLD
	run.deck = STARTER_DECK.duplicate()
	run.act = 1
	run.map_seed = randi()
	run.current_node_id = -1
	run.visited_nodes = []
	return run


static func from_dict(data: Dictionary) -> RunData:
	var run := RunData.new()
	run.health = data.get("health", STARTING_HEALTH)
	run.max_health = data.get("max_health", STARTING_HEALTH)
	run.gold = data.get("gold", STARTING_GOLD)
	run.deck = data.get("deck", [])
	run.act = data.get("act", 1)
	run.map_seed = data.get("map_seed", 0)
	run.current_node_id = data.get("current_node_id", -1)
	run.visited_nodes = data.get("visited_nodes", [])
	return run


func to_dict() -> Dictionary:
	return {
		"health": health,
		"max_health": max_health,
		"gold": gold,
		"deck": deck,
		"act": act,
		"map_seed": map_seed,
		"current_node_id": current_node_id,
		"visited_nodes": visited_nodes,
	}
