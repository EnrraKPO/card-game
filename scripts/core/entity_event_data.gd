class_name EntityEventData
extends EventData

# The one class for entity-bearing facts (Core System Design §8): role — what the
# entities are to the happening (`targets` among them) — and the entities; a singular
# fact rides as a set of one.

var role: StringName = &""
var entities: Array[GameEntity] = []


func _init(p_role: StringName, p_entities: Array[GameEntity]) -> void:
	role = p_role
	entities = p_entities
