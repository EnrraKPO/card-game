class_name NameIsCondition
extends EventDataCondition

# `name_is` (A8): members role and name. True when the occasion carries a NameEventData
# of that role bearing that name. The kind of the §9 example and the baked ability-name
# condition.

var role: StringName = &""
var name: StringName = &""


func _answer(_plate: Plate, subject: Event) -> bool:
	for component: EventData in subject.components_of(NameEventData):
		var named := component as NameEventData
		if named.role == role and named.name == name:
			return true
	return false
