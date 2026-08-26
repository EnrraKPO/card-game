class_name ContainerMoveProcedure
extends EngineProcedure

# Resolves a container move (Mutation System Design §7): removes the target from its
# housing, inserts it at the destination — one procedure performing the two membership
# primitives (Core §2). Draw, burial, discard, placement, movement.
#
# It stamps the origin and destination housing as NameEventData — roles `origin` and
# `destination`, each bearing the housing container's name — on the event it produces,
# and produces `fielded` (source the arriving unit) when the destination is a
# `slotted_unit` container and the stamped origin housing is not (Core §2). Every route
# onto the board passes through this insert. Other moves produce no event yet — a fact
# event exists only where content cares (Mutation §8).


static func resolve(request: ContainerMoveRequest) -> Array[Event]:
	var target: GameEntity = request.target
	var origin: EntityContainer = target.housing
	if origin == null:
		push_error("ContainerMoveProcedure: the target is unhoused — a move needs a housing to leave")
		return []
	var destination: EntityContainer = request.destination_owner.get_container(
			request.destination_container)
	if destination == null:
		return []
	WriteAuthority.remove(origin, target)
	WriteAuthority.insert(destination, target)
	var events: Array[Event] = []
	if destination.name == &"slotted_unit" and origin.name != &"slotted_unit":
		var fielded := Event.new(&"fielded", request.source, request.target)
		fielded.components.append(NameEventData.new(&"origin", origin.name))
		fielded.components.append(NameEventData.new(&"destination", destination.name))
		target.world.outlet.cue(&"card_placed", target, 0.0)   # its cue at commit (MSD s10)
		events.append(fielded)
	return events
