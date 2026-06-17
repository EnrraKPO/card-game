class_name CardInstance
extends RefCounted

var data: CardData
var current_health: int
var current_shield: int
var row: int = -1
var col: int = -1
var owner: int = -1  # 0 = player, 1 = enemy
var modifiers: Dictionary = {}  # attribute id -> cumulative int delta

# Set true for the round when this unit spent its attack to generate a card
# (see rook/building generation in combat.gd). Reset at the start of each round.
var attack_exhausted: bool = false
# On a rook-generated token, points back to the building that produced it so
# playing the token can exhaust that building's attack. Null on normal units.
var source_building: CardInstance = null

var is_spell: bool:
	get: return data != null and data.card_type == CardData.CardType.SPELL


static func from_data(card_data: CardData) -> CardInstance:
	var inst := CardInstance.new()
	inst.data = card_data
	inst.current_health = card_data.health
	inst.current_shield = card_data.shield
	return inst


# Returns the effective value of an attribute, base + any accumulated modifiers.
func get_attribute(attr: String) -> int:
	match attr:
		"health":     return current_health
		"max_health": return data.health    + modifiers.get("max_health", 0)
		"attack":     return data.attack    + modifiers.get("attack",     0)
		"speed":      return data.speed     + modifiers.get("speed",      0)
		"cost":       return data.cost      + modifiers.get("cost",       0)
		"shield":     return current_shield
		_:            return modifiers.get(attr, 0)


func apply_modifier(attr: String, delta: int) -> void:
	modifiers[attr] = modifiers.get(attr, 0) + delta


func take_damage(amount: int) -> Dictionary:
	var absorbed := 0
	if current_shield > 0:
		absorbed = mini(amount, current_shield)
		current_shield -= absorbed
		amount -= absorbed
	current_health -= amount
	return {"shield_absorbed": absorbed, "health_damage": amount}


func restore_shield() -> void:
	current_shield = data.shield + modifiers.get("shield", 0)


func is_alive() -> bool:
	return current_health > 0
