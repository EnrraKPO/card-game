class_name CardData
extends RefCounted

var id: String
var display_name: String
var cost: int
var attack: int
var health: int
var speed: int
var is_king: bool

static var _all: Dictionary = {}


static func _static_init() -> void:
	_reg("king",     "King",     0, 1,  20, 3, true)
	_reg("strike",   "Strike",   1, 4,  3,  5)
	_reg("defender", "Defender", 2, 1,  8,  2)
	_reg("swift",    "Swift",    1, 2,  2,  8)
	_reg("warrior",  "Warrior",  3, 6,  6,  3)
	_reg("archer",   "Archer",   2, 3,  3,  6)


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
