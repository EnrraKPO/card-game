class_name NameEventData
extends EventData

# A named fact (Core System Design §8): role — what the name means to the happening
# (`mutator_kind` and `ability` among them, `origin` and `destination` for a move's
# stamped housings, §2) — and the name itself.

var role: StringName = &""
var name: StringName = &""


func _init(p_role: StringName, p_name: StringName) -> void:
	role = p_role
	name = p_name
