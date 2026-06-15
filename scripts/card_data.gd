class_name CardData
extends RefCounted

enum CardType { UNIT, SPELL }

var id: String
var display_name: String
var cost: int
var attack: int
var health: int
var speed: int
var is_king: bool
var card_type: CardType = CardType.UNIT
var description: String = ""
var effects: Array = []  # Array[Effect]
var image: Texture2D = null
var elements: Array[String] = []
var chess_pieces: Array[String] = []

static var _all: Dictionary = {}
static var _by_composition: Dictionary = {}


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
	card.elements     = Array(d.get("elements",     []), TYPE_STRING, "", null)
	card.chess_pieces = Array(d.get("chess_pieces", []), TYPE_STRING, "", null)
	if d.has("card_type"):
		card.card_type = CardType.SPELL if d.get("card_type") == "spell" else CardType.UNIT
	elif not card.elements.is_empty() and card.chess_pieces.is_empty():
		card.card_type = CardType.SPELL
	else:
		card.card_type = CardType.UNIT
	if card.elements.size() > 0 or card.chess_pieces.size() > 0:
		_by_composition[composition_key(card.elements, card.chess_pieces)] = card


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
		"manual":         return Effect.TargetingPolicy.MANUAL
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
	if _all.has(p_id):
		return _all[p_id]
	return _derive_from_key(p_id)


static func all() -> Array:
	return _all.values()


static func composition_key(elems: Array, chess: Array) -> String:
	var e := elems.duplicate(); e.sort()
	var c := chess.duplicate(); c.sort()
	return "_".join(e + c)


static func can_combine(a: CardData, b: CardData) -> bool:
	return (a.elements.size() + b.elements.size()) <= 2 \
		and (a.chess_pieces.size() + b.chess_pieces.size()) <= 2


static func combine(a: CardData, b: CardData) -> CardData:
	var elems: Array = a.elements + b.elements
	var chess: Array  = a.chess_pieces + b.chess_pieces
	var key := composition_key(elems, chess)
	var authored: CardData = _by_composition.get(key, null)
	if authored:
		return authored
	var derived := _derive(elems, chess, key)
	_all[key]            = derived
	_by_composition[key] = derived
	return derived


static func _derive_from_key(key: String) -> CardData:
	if key.is_empty():
		return null
	var elems: Array[String] = []
	var chess: Array[String]  = []
	for part: String in key.split("_"):
		var base: CardData = _all.get(part, null)
		if base == null or (base.elements.is_empty() and base.chess_pieces.is_empty()):
			return null
		elems.append_array(base.elements)
		chess.append_array(base.chess_pieces)
	if elems.is_empty() and chess.is_empty():
		return null
	var derived := _derive(elems, chess, key)
	_all[key]            = derived
	_by_composition[key] = derived
	return derived


static func _derive(elems: Array, chess: Array, key: String) -> CardData:
	var c := CardData.new()
	c.id           = key
	c.elements     = Array(elems, TYPE_STRING, "", null)
	c.chess_pieces = Array(chess, TYPE_STRING, "", null)
	c.is_king      = false
	c.display_name = _derive_name(elems, chess)
	c.description  = ""
	var n := elems.size() + chess.size()
	var cost := 0
	for e: String in elems:
		var base: CardData = _all.get(e, null)
		cost += base.cost if base else 1
	for cp: String in chess:
		var base: CardData = _all.get(cp, null)
		cost += base.cost if base else 1
	c.cost        = cost
	c.attack      = n * 2
	c.health      = n * 3
	c.speed       = 2
	c.card_type   = CardType.SPELL if (chess.is_empty() and not elems.is_empty()) else CardType.UNIT
	var art := "res://assets/cards/%s.png" % key
	c.image = load(art) if ResourceLoader.exists(art) \
		else load("res://assets/cards/placeholder.png")
	return c


static func _derive_name(elems: Array, chess: Array) -> String:
	const INITIALS := {
		"fire": "F", "water": "W", "air": "A", "earth": "E",
		"darkness": "D", "light": "L",
		"pawn": "P", "bishop": "B", "knight": "K",
		"rook": "R", "queen": "Q", "king": "C",
	}
	var e := elems.duplicate(); e.sort()
	var c := chess.duplicate(); c.sort()
	var name := ""
	for mat: String in e:
		name += INITIALS.get(mat, mat[0].to_upper())
	for mat: String in c:
		name += INITIALS.get(mat, mat[0].to_upper())
	return name
