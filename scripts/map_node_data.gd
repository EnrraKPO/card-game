class_name MapNodeData
extends RefCounted

enum Type { COMBAT, ELITE, EVENT, SHOP, REST, BOSS, FORGE }

var id: int
var floor: int
var column: int
var type: Type
var connections: Array = []
var visited: bool = false
# For EVENT ("?") nodes: which event this site runs — "trainer" (the stat-upgrade event) or
# "relic" (offers a free relic). Rolled at map generation from the seeded RNG. See MapData.generate.
var event_kind: String = "trainer"
# For "trainer" EVENT nodes: the card stat this site can upgrade. Assigned at map
# generation from the seeded RNG, so it's stable across reloads (the map is rebuilt
# from the seed). Empty for non-event nodes. See MapData.generate.
var event_attr: String = ""
# For COMBAT/ELITE nodes: the profile resources (id→count) won here, assigned at map
# generation from the seeded RNG (so it's stable across reloads and previewable on the
# map before you fight). Empty for other node types. See MapData.generate.
var material_rewards: Dictionary = {}


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


# Black-silhouette icon for each node type, drawn inside the medallion with the
# icon-outline shader (see MapNodeMedallion). ELITE reuses the "epic combat" art;
# rest/boss/forge are placeholder copies of the generic event icon for now.
const _ICONS := {
	Type.COMBAT: preload("res://assets/ui/icons/combat_icon.png"),
	Type.ELITE:  preload("res://assets/ui/icons/combat_epic_icon.png"),
	Type.EVENT:  preload("res://assets/ui/icons/event_generic_icon.png"),
	Type.SHOP:   preload("res://assets/ui/icons/shop_icon.png"),
	Type.REST:   preload("res://assets/ui/icons/rest_icon.png"),
	Type.BOSS:   preload("res://assets/ui/icons/boss_icon.png"),
	Type.FORGE:  preload("res://assets/ui/icons/forge_icon.png"),
}


static func get_icon(t: Type) -> Texture2D:
	return _ICONS.get(t, null)
