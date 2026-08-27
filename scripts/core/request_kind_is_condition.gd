class_name RequestKindIsCondition
extends EventDataCondition

# `request_kind_is` (Kind Rosters §1): one member, name. True when the occasion's stamped
# RequestEventData carries a request whose mutator_kind is the name. The kind of Core
# §9's example; deeper request-reading enters when content asks.

var name: StringName = &""


func _answer(_plate: Plate, subject: Event) -> bool:
	for component: EventData in subject.components_of(RequestEventData):
		var stamped := component as RequestEventData
		if stamped.request != null and stamped.request.mutator_kind == name:
			return true
	return false
