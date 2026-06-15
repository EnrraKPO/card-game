class_name MapNodeData
extends RefCounted

enum Type { COMBAT, ELITE, EVENT, SHOP, REST, BOSS, FORGE }

var id: int
var floor: int
var column: int
var type: Type
var connections: Array = []
var visited: bool = false


static func get_label(t: Type) -> String:
	match t:
		Type.COMBAT: return "Fight"
		Type.ELITE:  return "Elite"
		Type.EVENT:  return "?"
		Type.SHOP:   return "Shop"
		Type.REST:   return "Rest"
		Type.BOSS:   return "Boss"
		Type.FORGE:  return "Forge"
	return "?"


static func get_color(t: Type) -> Color:
	match t:
		Type.COMBAT: return Color(0.75, 0.25, 0.25)
		Type.ELITE:  return Color(0.55, 0.15, 0.75)
		Type.EVENT:  return Color(0.75, 0.65, 0.15)
		Type.SHOP:   return Color(0.20, 0.65, 0.30)
		Type.REST:   return Color(0.15, 0.55, 0.65)
		Type.BOSS:   return Color(0.85, 0.35, 0.10)
		Type.FORGE:  return Color(0.80, 0.55, 0.10)
	return Color.WHITE
