class_name CardInstance
extends RefCounted

var data: CardData
var current_health: int
var current_shield: int
var row: int = -1
var col: int = -1
var owner: int = -1  # 0 = player, 1 = enemy
var modifiers: Dictionary = {}  # attribute id -> cumulative int delta
# Charm ids attached to this card (display only — their mechanics are already baked into
# `data` by DeckCard.make_instance). Empty for enemies, kings, and tokens.
var charms: Array = []

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


# Returns the effective value of an attribute: base + this instance's accumulated modifiers
# (from triggered effects / charms) + any run-wide CARD modifiers that match this card
# (upgrades/relics, resolved at read-time — see GameData.card_bonus, guarded to player units).
func get_attribute(attr: String) -> int:
	match attr:
		"health":     return current_health
		"max_health": return data.health + modifiers.get("max_health", 0) + GameData.card_bonus(self, "max_health")
		"attack":     return data.attack + modifiers.get("attack",     0) + GameData.card_bonus(self, "attack")
		"speed":      return data.speed  + modifiers.get("speed",      0)
		"cost":       return data.cost   + modifiers.get("cost",       0) + GameData.card_bonus(self, "cost")
		"shield":     return current_shield
		_:            return modifiers.get(attr, 0)


func apply_modifier(attr: String, delta: int) -> void:
	modifiers[attr] = modifiers.get(attr, 0) + delta


func take_damage(amount: int) -> Dictionary:
	# Damage never heals: a sub-zero attack (units may have <0 Attack) deals 0, not
	# negative. Clamping here keeps the invariant for every damage source, not just attacks.
	amount = maxi(0, amount)
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
