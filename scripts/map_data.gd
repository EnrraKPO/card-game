class_name MapData
extends RefCounted

const FLOORS := 10
# Lanes in the grid the map is carved into. A node lives at a (floor, lane) cell only if a
# carved path visits it, so floors hold a VARIABLE number of nodes (1..MAP_WIDTH). Node ids
# stay `floor * MAP_WIDTH + lane`, so they're stable across reloads and the boss id is fixed.
const MAP_WIDTH := 5
# How many random walks are carved from the bottom floor up to the boss. More paths = more
# nodes per floor and a denser web; fewer = sparser, more linear. Tune alongside MAP_WIDTH.
const PATHS := 5
# The boss sits alone on the top floor in the centre lane.
const BOSS_COL := MAP_WIDTH / 2
# How many stages (acts) a full run spans; the last stage's boss is the final boss.
const STAGES := 3


# The boss is always the lone centre node on the top floor, so its id is deterministic
# across every generated map. Standing on it means the stage has been cleared.
static func boss_node_id() -> int:
	return (FLOORS - 1) * MAP_WIDTH + BOSS_COL

# Fallback used only if data/map/node_weights.json is missing or has no row
# covering a given floor — keeps generation from breaking outright.
const _FALLBACK_WEIGHTS := {"combat": 0.45, "rest": 0.22, "event": 0.17, "shop": 0.16}

static var _weight_rows: Array = []  # Array[{"min_floor", "max_floor", "weights"}]


var floors: Array = []


# `repeat_drop` / `recovery` drive the anti-clustering cooldown: a rolled node type's weight
# drops to `repeat_drop` of normal the moment it's used, then recovers to full over `recovery`
# generated nodes. recovery <= 0 (the default) disables it — behaviour identical to before.
static func generate(seed_val: int, repeat_drop: float = 1.0, recovery: int = 0) -> MapData:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var map := MapData.new()
	# Shared across every weighted type roll, in generation order, so types remember how
	# recently they were used. "idx" = weighted-roll counter, "last" = type -> last idx used.
	var picker := {"idx": 0, "last": {}, "drop": repeat_drop, "recovery": recovery}

	# Floors 0..FLOORS-2 are carved by the random walks; the top floor is the lone boss.
	var walk_floors: int = FLOORS - 1

	# Carve PATHS random walks bottom-to-top. `present["f:c"]` flags an occupied cell;
	# `step_edges[f]` collects the (from_lane, to_lane) edges added between floor f and f+1,
	# so new edges can be rejected when they'd cross one already drawn at that step.
	var present: Dictionary = {}
	var step_edges: Dictionary = {}
	for f in walk_floors:
		step_edges[f] = []

	for _p in PATHS:
		var col: int = rng.randi_range(0, MAP_WIDTH - 1)
		_mark(present, 0, col)
		for f in walk_floors - 1:
			var nxt: int = _next_col(rng, col, step_edges[f])
			step_edges[f].append([col, nxt])
			_mark(present, f + 1, nxt)
			col = nxt

	# Realise the occupied cells as nodes.
	for f in walk_floors:
		var floor_nodes: Array = []
		for c in MAP_WIDTH:
			if present.has("%d:%d" % [f, c]):
				floor_nodes.append(_make_node(f, c, rng, picker))
		map.floors.append(floor_nodes)

	# The boss floor: one node, centre lane, reached from every penultimate-floor node.
	var boss := _make_node(FLOORS - 1, BOSS_COL, rng, picker)
	map.floors.append([boss])

	# Turn the carved edges into node connections.
	for f: int in step_edges:
		for e: Array in step_edges[f]:
			var a: MapNodeData = map.get_node_at(f, e[0])
			var b: MapNodeData = map.get_node_at(f + 1, e[1])
			if a != null and b != null and b.id not in a.connections:
				a.connections.append(b.id)
	for node: MapNodeData in map.floors[walk_floors - 1]:
		if boss.id not in node.connections:
			node.connections.append(boss.id)

	for floor_nodes: Array in map.floors:
		for node: MapNodeData in floor_nodes:
			node.connections.sort()

	return map


static func _mark(present: Dictionary, floor: int, col: int) -> void:
	present["%d:%d" % [floor, col]] = true


# Pick the next lane for a walk leaving `col`, among {col-1, col, col+1} (clamped to the
# grid), skipping any move that would cross an edge already carved at this step. Straight
# moves can never cross, so an option always exists; straight is weighted a little heavier
# to keep paths from zig-zagging every floor.
static func _next_col(rng: RandomNumberGenerator, col: int, edges: Array) -> int:
	var pool: Array = []
	for d in [-1, 0, 1]:
		var nc: int = col + d
		if nc < 0 or nc >= MAP_WIDTH:
			continue
		if _crosses(edges, col, nc):
			continue
		pool.append(nc)
	if pool.is_empty():
		return col
	return pool[rng.randi() % pool.size()]


# Two edges (a→b) and (c→d) on the same floor step cross when their lanes swap order.
static func _crosses(edges: Array, c: int, d: int) -> bool:
	for e: Array in edges:
		var a: int = e[0]
		var b: int = e[1]
		if (c < a and d > b) or (c > a and d < b):
			return true
	return false


static func _make_node(f: int, c: int, rng: RandomNumberGenerator, picker: Dictionary) -> MapNodeData:
	var node := MapNodeData.new()
	node.id = f * MAP_WIDTH + c
	node.floor = f
	node.column = c
	node.type = _pick_type(f, rng, picker)
	if node.type == MapNodeData.Type.EVENT:
		# Most "?" sites are the stat trainer; some offer a free relic instead.
		if rng.randf() < 0.4:
			node.event_kind = "relic"
		else:
			node.event_kind = "trainer"
			node.event_attr = DeckCard.UPGRADABLE[rng.randi() % DeckCard.UPGRADABLE.size()]
	elif node.type == MapNodeData.Type.ELITE:
		# Elites drop a chess piece — the king-alchemy currency (the Forge needs a King
		# Piece). Placeholder: one random piece, uniform odds (balance later).
		var piece: String = Materials.PIECES[rng.randi() % Materials.PIECES.size()]
		node.material_rewards = {Materials.piece_id(piece): 1}
	elif node.type == MapNodeData.Type.COMBAT:
		# Previewable essence reward: a single random element, modest fixed amount
		# (balance/authoring is a later pass).
		var element: String = Materials.ELEMENTS[rng.randi() % Materials.ELEMENTS.size()]
		node.material_rewards = {element: 2}
	return node


static func _pick_type(floor: int, rng: RandomNumberGenerator, picker: Dictionary) -> MapNodeData.Type:
	if floor == FLOORS - 1:
		return MapNodeData.Type.BOSS
	if floor == FLOORS - 2:
		return MapNodeData.Type.ELITE
	if floor == 0:
		return MapNodeData.Type.COMBAT

	var weights: Dictionary = _weights_for_floor(floor)
	var keys: Array = weights.keys()
	var idx: int = picker["idx"]
	var last: Dictionary = picker["last"]
	var drop: float = picker["drop"]
	var recovery: int = picker["recovery"]
	# Effective weight = base × cooldown factor. A type used `ago` rolls back sits at
	# `drop` when ago == 1 (just used) and climbs to full by ago == recovery + 1. Combat is
	# exempt: it's the filler type, and suppressing it would only raise the others' share.
	var picked: String = WeightedRandom.pick(rng, keys, func(k: String) -> float:
		var w: float = weights[k]
		if recovery > 0 and k != "combat" and last.has(k):
			var ago: int = idx - int(last[k])
			var t: float = clampf(float(ago - 1) / float(recovery), 0.0, 1.0)
			w *= drop + (1.0 - drop) * t
		return w
	)
	last[picked] = idx
	picker["idx"] = idx + 1
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


func get_node_by_id(id: int) -> MapNodeData:
	for floor_nodes: Array in floors:
		for node: MapNodeData in floor_nodes:
			if node.id == id:
				return node
	return null


# Lookup by grid cell. Returns null if the (floor, lane) cell wasn't carved into a node.
func get_node_at(floor: int, col: int) -> MapNodeData:
	return get_node_by_id(floor * MAP_WIDTH + col)


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
