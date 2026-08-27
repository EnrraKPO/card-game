class_name Event
extends RefCounted

# An event is a core plus components (Core System Design §8). The core: the source — the
# entity the happening comes from; any GameEntity may be one — the target — one
# GameEntity, carried at all times: the Game until a resolver elects one (§4) — and
# the event's name. Components are an Array[EventData], appended by each layer of the
# road that knows a fact of the happening (accretion is open to anything on the road).
#
# The target propagates into the branching events the cascade produces, and forwards
# into requests, which carry it until they appoint a new target (§4).
#
# Ask events are imperative verbs (play, use_ability, act); happening events are past
# tense (play_engaged, ability_used, died) — §7.
#
# Events are transient: they live for one delivery's holster and die when their
# consequences have unfolded (Mutation §9), so the core references are strong — nothing
# an event references ever references the event back.

var source: GameEntity = null
var target: GameEntity = null
var name: StringName = &""
var components: Array[EventData] = []


func _init(p_name: StringName, p_source: GameEntity, p_target: GameEntity) -> void:
	name = p_name
	source = p_source
	target = p_target


# The one read (§8): a reader names a component class and receives all matching
# components, reading their typed members. An event may carry several components of one
# shape; the reader governs its use of them.
func components_of(shape: Script) -> Array[EventData]:
	var out: Array[EventData] = []
	for c: EventData in components:
		if is_instance_of(c, shape):
			out.append(c)
	return out
