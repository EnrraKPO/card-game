class_name MapState
extends RefCounted

var map_seed: int
var current_node_id: int = -1
var visited_nodes: Array = []


static func create_new() -> MapState:
	var state := MapState.new()
	state.map_seed = randi()
	state.current_node_id = -1
	state.visited_nodes = []
	return state


static func from_dict(data: Dictionary) -> MapState:
	var state := MapState.new()
	state.map_seed       = data.get("map_seed", 0)
	state.current_node_id = data.get("current_node_id", -1)
	state.visited_nodes  = data.get("visited_nodes", [])
	return state


func to_dict() -> Dictionary:
	return {
		"map_seed":        map_seed,
		"current_node_id": current_node_id,
		"visited_nodes":   visited_nodes,
	}
