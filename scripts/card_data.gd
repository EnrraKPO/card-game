class_name CardData
extends RefCounted

var id: String
var display_name: String
var cost: int
var attack: int
var health: int
var speed: int
var is_king: bool
var description: String = ""
var effects: Array = []  # Array[Effect]
var image: Texture2D = null

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/cards/")
	if dir == null:
		push_error("CardData: cannot open res://data/cards/")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/cards/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("CardData: cannot open " + path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("CardData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = []
	if json.data is Array:
		entries = json.data
	else:
		entries = [json.data]
	for d: Dictionary in entries:
		_load_card_dict(d)


static func _load_card_dict(d: Dictionary) -> void:
	_reg(
		d.get("id", ""),
		d.get("display_name", ""),
		d.get("cost", 0),
		d.get("attack", 0),
		d.get("health", 1),
		d.get("speed", 1),
		d.get("is_king", false)
	)
	var card := get_card(d.get("id", ""))
	if card == null:
		return
	card.description = d.get("description", "")
	var art_path := "res://assets/cards/%s.png" % card.id
	if ResourceLoader.exists(art_path):
		card.image = load(art_path)
	else:
		card.image = load("res://assets/cards/placeholder.png")
	for e_data: Dictionary in d.get("effects", []):
		var e := _parse_effect(e_data)
		if e:
			card.effects.append(e)


static func _parse_effect(d: Dictionary) -> Effect:
	var conditions: Array = []
	for c_data: Dictionary in d.get("conditions", []):
		var c := _parse_condition(c_data)
		if c:
			conditions.append(c)
	return Effect.make(
		_str_trigger(d.get("trigger", "")),
		_str_policy(d.get("targeting_policy", "")),
		d.get("attribute", ""),
		d.get("amount", 0),
		conditions
	)


static func _parse_condition(d: Dictionary) -> EffectCondition:
	return EffectCondition.make(
		d.get("attribute", ""),
		_str_comparator(d.get("comparator", "")),
		d.get("value", 0)
	)


static func _str_trigger(s: String) -> Effect.Trigger:
	match s:
		"on_play":         return Effect.Trigger.ON_PLAY
		"on_death":        return Effect.Trigger.ON_DEATH
		"on_attack":       return Effect.Trigger.ON_ATTACK
		"on_damage_taken": return Effect.Trigger.ON_DAMAGE_TAKEN
		"permanent":       return Effect.Trigger.PERMANENT
	return Effect.Trigger.ON_PLAY


static func _str_policy(s: String) -> Effect.TargetingPolicy:
	match s:
		"self":           return Effect.TargetingPolicy.SELF
		"single_nearest": return Effect.TargetingPolicy.SINGLE_NEAREST
		"single_random":  return Effect.TargetingPolicy.SINGLE_RANDOM
		"all_enemies":    return Effect.TargetingPolicy.ALL_ENEMIES
		"all_allies":     return Effect.TargetingPolicy.ALL_ALLIES
		"all":            return Effect.TargetingPolicy.ALL
	return Effect.TargetingPolicy.SELF


static func _str_comparator(s: String) -> EffectCondition.Comparator:
	match s:
		"gt":  return EffectCondition.Comparator.GT
		"gte": return EffectCondition.Comparator.GTE
		"lt":  return EffectCondition.Comparator.LT
		"lte": return EffectCondition.Comparator.LTE
		"eq":  return EffectCondition.Comparator.EQ
		"neq": return EffectCondition.Comparator.NEQ
	return EffectCondition.Comparator.GTE


static func _reg(p_id: String, p_name: String, p_cost: int, p_atk: int, p_hp: int, p_spd: int, p_king: bool = false) -> void:
	var c := CardData.new()
	c.id = p_id
	c.display_name = p_name
	c.cost = p_cost
	c.attack = p_atk
	c.health = p_hp
	c.speed = p_spd
	c.is_king = p_king
	_all[p_id] = c


static func get_card(p_id: String) -> CardData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()
