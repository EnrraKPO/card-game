class_name MapData
extends RefCounted

const FLOORS := 10
const NODES_PER_FLOOR := 3


var floors: Array = []


static func generate(seed_val: int) -> MapData:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var map := MapData.new()

	for f in FLOORS:
		var floor_nodes: Array = []
		var count: int = 1 if f == FLOORS - 1 else NODES_PER_FLOOR
		for c in count:
			var node := MapNodeData.new()
			node.id = f * NODES_PER_FLOOR + c
			node.floor = f
			node.column = c
			node.type = _pick_type(f, rng)
			floor_nodes.append(node)
		map.floors.append(floor_nodes)

	_generate_connections(map, rng)
	return map


static func _pick_type(floor: int, rng: RandomNumberGenerator) -> MapNodeData.Type:
	if floor == FLOORS - 1:
		return MapNodeData.Type.BOSS
	if floor == FLOORS - 2:
		return MapNodeData.Type.ELITE
	if floor == 0:
		return MapNodeData.Type.COMBAT

	var roll: float = rng.randf()
	if roll < 0.45:
		return MapNodeData.Type.COMBAT
	elif roll < 0.67:
		return MapNodeData.Type.REST
	elif roll < 0.84:
		return MapNodeData.Type.EVENT
	else:
		return MapNodeData.Type.SHOP


static func _generate_connections(map: MapData, rng: RandomNumberGenerator) -> void:
	for f in FLOORS - 1:
		var cur_floor: Array = map.floors[f]
		var next_floor: Array = map.floors[f + 1]
		var next_count: int = next_floor.size()

		if next_count == 1:
			for node: MapNodeData in cur_floor:
				node.connections.append(next_floor[0].id)
			continue

		for node: MapNodeData in cur_floor:
			var c: int = node.column
			var primary: int = clamp(c + rng.randi_range(-1, 1), 0, next_count - 1)
			node.connections.append(next_floor[primary].id)

			if rng.randf() < 0.30:
				var dir: int = 1 if primary == 0 else -1
				var secondary: int = primary + dir
				if secondary >= 0 and secondary < next_count:
					var sid: int = next_floor[secondary].id
					if sid not in node.connections:
						node.connections.append(sid)

			node.connections.sort()

		for nc in next_count:
			var next_node: MapNodeData = next_floor[nc]
			var reachable: bool = false
			for node: MapNodeData in cur_floor:
				if next_node.id in node.connections:
					reachable = true
					break
			if not reachable:
				var src: MapNodeData = cur_floor[clamp(nc, 0, cur_floor.size() - 1)]
				if next_node.id not in src.connections:
					src.connections.append(next_node.id)
					src.connections.sort()


func get_node_by_id(id: int) -> MapNodeData:
	for floor_nodes: Array in floors:
		for node: MapNodeData in floor_nodes:
			if node.id == id:
				return node
	return null


func get_reachable_nodes(current_id: int) -> Array:
	if current_id == -1:
		return floors[0].duplicate()
	var current: MapNodeData = get_node_by_id(current_id)
	if current == null:
		return []
	var result: Array = []
	for next_id: int in current.connections:
		var n: MapNodeData = get_node_by_id(next_id)
		if n != null:
			result.append(n)
	return result
