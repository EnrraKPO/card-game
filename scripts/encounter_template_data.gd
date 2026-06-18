class_name EncounterTemplateData
extends RefCounted

var id: String = ""
var node_type: MapNodeData.Type = MapNodeData.Type.COMBAT
var min_floor: int = 0
var max_floor: int = 999
# Stage (act) band this template is eligible for — the difficulty-scaling knob. Author
# tougher templates (bigger enemy_pool / pick_count / stats) tagged to later stages.
var min_stage: int = 1
var max_stage: int = 999
var weight: float = 1.0
var enemy_pool: Array = []   # Array[{ "id": String, "weight": float }]
var pick_count: Array = [1, 1]    # [min, max] inclusive
var gold_reward: Array = [0, 0]   # [min, max] inclusive
var ai: String = "default"
var reward_pool: String = "default"

static var _all: Array = []  # Array[EncounterTemplateData]


# ── Loading ─────────────────────────────────────────────────────────────────

static func _static_init() -> void:
	var dir := DirAccess.open("res://data/encounters/")
	if dir == null:
		push_error("EncounterTemplateData: cannot open res://data/encounters/")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/encounters/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("EncounterTemplateData: cannot open " + path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("EncounterTemplateData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = []
	if json.data is Array:
		entries = json.data
	else:
		entries = [json.data]
	for d: Dictionary in entries:
		_all.append(_from_dict(d))


static func _from_dict(d: Dictionary) -> EncounterTemplateData:
	var t := EncounterTemplateData.new()
	t.id          = d.get("id", "")
	t.node_type   = _str_node_type(d.get("node_type", "combat"))
	t.min_floor   = d.get("min_floor", 0)
	t.max_floor   = d.get("max_floor", 999)
	t.min_stage   = d.get("min_stage", 1)
	t.max_stage   = d.get("max_stage", 999)
	t.weight      = d.get("weight", 1.0)
	t.ai          = d.get("ai", "default")
	t.reward_pool = d.get("reward_pool", "default")
	var pc: Array = d.get("pick_count", [1, 1])
	t.pick_count  = [pc[0], pc[0] if pc.size() < 2 else pc[1]]
	var gr: Array = d.get("gold_reward", [0, 0])
	t.gold_reward = [gr[0], gr[0] if gr.size() < 2 else gr[1]]
	for e: Dictionary in d.get("enemy_pool", []):
		t.enemy_pool.append({"id": e.get("id", ""), "weight": e.get("weight", 1.0)})
	return t


static func _str_node_type(s: String) -> MapNodeData.Type:
	match s:
		"combat": return MapNodeData.Type.COMBAT
		"elite":  return MapNodeData.Type.ELITE
		"boss":   return MapNodeData.Type.BOSS
	push_error("EncounterTemplateData: unknown node_type '%s', defaulting to combat" % s)
	return MapNodeData.Type.COMBAT


# ── Selection ───────────────────────────────────────────────────────────────

# Picks a template matching node_type whose floor AND stage bands contain `floor`/`stage`.
# Falls back to ignoring the bands (any template of that node_type) if nothing matches
# exactly, so a gap in authored coverage degrades gracefully instead of crashing.
static func pick_for(p_node_type: MapNodeData.Type, floor: int, stage: int, rng: RandomNumberGenerator) -> EncounterTemplateData:
	var in_band: Array = _all.filter(func(t: EncounterTemplateData) -> bool:
		return t.node_type == p_node_type \
			and floor >= t.min_floor and floor <= t.max_floor \
			and stage >= t.min_stage and stage <= t.max_stage
	)
	var candidates: Array = in_band if not in_band.is_empty() else \
		_all.filter(func(t: EncounterTemplateData) -> bool: return t.node_type == p_node_type)

	if candidates.is_empty():
		push_error("EncounterTemplateData: no template found for node_type %s" % p_node_type)
		return null

	return WeightedRandom.pick(rng, candidates, func(t: EncounterTemplateData) -> float: return t.weight)


# ── Instantiation ───────────────────────────────────────────────────────────

func instantiate(rng: RandomNumberGenerator) -> EncounterData:
	var enc := EncounterData.new()
	enc.type = _encounter_data_type(node_type)
	enc.ai   = EnemyAI.from_key(ai)

	var count: int = rng.randi_range(pick_count[0], pick_count[1])
	var deck: Array[String] = []
	if not enemy_pool.is_empty():
		for i in count:
			var entry: Dictionary = WeightedRandom.pick(rng, enemy_pool, func(e: Dictionary) -> float: return e.weight)
			deck.append(entry.id)
	enc.enemy_deck = deck

	enc.gold_reward = rng.randi_range(gold_reward[0], gold_reward[1])
	enc.reward_pool = resolve_reward_pool(reward_pool)
	return enc


static func _encounter_data_type(t: MapNodeData.Type) -> EncounterData.Type:
	match t:
		MapNodeData.Type.ELITE: return EncounterData.Type.ELITE
		MapNodeData.Type.BOSS:  return EncounterData.Type.BOSS
	return EncounterData.Type.COMBAT


# ── Reward pools ────────────────────────────────────────────────────────────

# Named reward-pool strategies, keyed by the "reward_pool" string in template
# JSON. Add a new match arm here to introduce e.g. tag-filtered pools later.
static func resolve_reward_pool(key: String) -> Array[String]:
	match key:
		"default", "":
			return CardData.random_non_kings(3)
		_:
			push_error("EncounterTemplateData: unknown reward_pool key '%s', falling back to default" % key)
			return resolve_reward_pool("default")
