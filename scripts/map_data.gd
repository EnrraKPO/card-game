class_name MapData
extends RefCounted

const FLOORS := 10
const NODES_PER_FLOOR := 3

# Fallback used only if data/map/node_weights.json is missing or has no row
# covering a given floor — keeps generation from breaking outright.
const _FALLBACK_WEIGHTS := {"combat": 0.45, "rest": 0.22, "event": 0.17, "shop": 0.16}

static var _weight_rows: Array = []  # Array[{"min_floor", "max_floor", "weights"}]


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

	var weights: Dictionary = _weights_for_floor(floor)
	var keys: Array = weights.keys()
	var picked: String = WeightedRandom.pick(rng, keys, func(k: String) -> float: return weights[k])
	return _str_type(picked)


static func _weights_for_floor(floor: int) -> Dictionary:
	_ensure_weight_rows_loaded()
	for row: Dictionary in _weight_rows:
		if floor >= row.min_floor and floor <= row.max_floor:
			return row.weights
	push_error("MapData: no node_weights row covers floor %d, using fallback" % floor)
	return _FALLBACK_WEIGHTS


static func _str_type(s: String) -> MapNodeData.Type:
	match s:
		"combat": return MapNodeData.Type.COMBAT
		"rest":   return MapNodeData.Type.REST
		"event":  return MapNodeData.Type.EVENT
		"shop":   return MapNodeData.Type.SHOP
		"forge":  return MapNodeData.Type.FORGE
	push_error("MapData: unknown node type key '%s', defaulting to combat" % s)
	return MapNodeData.Type.COMBAT


static func _ensure_weight_rows_loaded() -> void:
	if not _weight_rows.is_empty():
		return
	var dir := DirAccess.open("res://data/map/")
	if dir == null:
		push_error("MapData: cannot open res://data/map/")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_weight_json("res://data/map/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_weight_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("MapData: cannot open " + path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("MapData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		_weight_rows.append({
			"min_floor": d.get("min_floor", 0),
			"max_floor": d.get("max_floor", 999),
			"weights":   d.get("weights", _FALLBACK_WEIGHTS),
		})


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
