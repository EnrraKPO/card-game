class_name CardInstance
extends RefCounted

var data: CardData
var current_health: int
var row: int = -1
var col: int = -1
var owner: int = -1  # 0 = player, 1 = enemy


static func from_data(card_data: CardData) -> CardInstance:
	var inst := CardInstance.new()
	inst.data = card_data
	inst.current_health = card_data.health
	return inst


func take_damage(amount: int) -> void:
	current_health -= amount


func is_alive() -> bool:
	return current_health > 0
