class_name Event
extends RefCounted

# An event is a core plus components (Core System Design §8). The core: the source — the
# entity the happening comes from; any GameEntity may be one — and the event's name.
# Components are an Array[EventData], appended by each layer of the road that knows a
# fact of the happening (accretion is open to anything on the road).
#
# Ask events are imperative verbs (play, use_ability, act); happening events are past
# tense (play_engaged, ability_used, died, fielded) — §7.
#
# Events are transient: they live for one delivery's holster and die when their
# consequences have unfolded (Mutation §9), so the source reference is strong — nothing
# an event references ever references the event back.

var source: GameEntity = null
var name: StringName = &""
var components: Array[EventData] = []


func _init(p_name: StringName, p_source: GameEntity) -> void:
	name = p_name
	source = p_source


# The one read (§8): a reader names a component class and receives all matching
# components, reading their typed members. An event may carry several components of one
# shape; the reader governs its use of them.
func components_of(shape: Script) -> Array[EventData]:
	var out: Array[EventData] = []
	for c: EventData in components:
		if is_instance_of(c, shape):
			out.append(c)
	return out
