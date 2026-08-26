class_name ContainerMoveProcedure
extends EngineProcedure

# Resolves a container move (Mutation System Design §7): removes the target from its
# housing, inserts it at the destination — one procedure performing the two membership
# primitives (Core §2). Draw, burial, discard, placement, movement.
#
# As T2 records it: at this scope no arrival event exists — this procedure mints none.
# A move produces no event yet — a fact event exists only where content cares (Mutation
# §8); when one enters, the move stamps its origin and destination housing on it as
# NameEventData, roles `origin` and `destination` (Core §2).


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
	if destination.name == &"slotted_unit" and origin.name != &"slotted_unit":
		target.world.outlet.cue(&"card_placed", target, 0.0)   # its cue at commit (MSD s10)
	return []
