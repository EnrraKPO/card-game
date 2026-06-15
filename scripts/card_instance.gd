class_name CardInstance
extends RefCounted

var data: CardData
var current_health: int
var row: int = -1
var col: int = -1
var owner: int = -1  # 0 = player, 1 = enemy
var modifiers: Dictionary = {}  # attribute id -> cumulative int delta


static func from_data(card_data: CardData) -> CardInstance:
	var inst := CardInstance.new()
	inst.data = card_data
	inst.current_health = card_data.health
	return inst


# Returns the effective value of an attribute, base + any accumulated modifiers.
func get_attribute(attr: String) -> int:
	match attr:
		"health":     return current_health
		"max_health": return data.health    + modifiers.get("max_health", 0)
		"attack":     return data.attack    + modifiers.get("attack",     0)
		"speed":      return data.speed     + modifiers.get("speed",      0)
		"cost":       return data.cost      + modifiers.get("cost",       0)
		_:            return modifiers.get(attr, 0)


func apply_modifier(attr: String, delta: int) -> void:
	modifiers[attr] = modifiers.get(attr, 0) + delta


func take_damage(amount: int) -> void:
	current_health -= amount


func is_alive() -> bool:
	return current_health > 0
