class_name HasStatusCondition
extends EntityCondition

# `has_status` (Core §9): one member, status_id. True when the subject's `contained`
# holds a Status of that id, read by checked downcast.

var status_id: StringName = &""


func _answer(_plate: Plate, subject: GameEntity) -> bool:
	for member: GameEntity in subject.get_container(&"contained").members:
		if member is Status and (member as Status).status_id == status_id:
			return true
	return false
