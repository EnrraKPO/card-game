class_name EntityEventData
extends EventData

# Entity-bearing facts: role — what the entities are to the happening — and the
# entities. Demoted from being a core mechanism in favor of the native event target
# (Core §8, A16). Its one remaining seat is the delivery's `targets` stamping, which the
# pre-A18 play road still reads (occasions_targets); the A18 rebuild retires both.

var role: StringName = &""
var entities: Array[GameEntity] = []


func _init(p_role: StringName, p_entities: Array[GameEntity]) -> void:
	role = p_role
	entities = p_entities
