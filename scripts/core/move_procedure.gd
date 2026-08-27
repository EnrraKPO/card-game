class_name MoveProcedure
extends EngineProcedure

# Resolves a container move (Mutation System Design §7): removes the cargo from its
# housing, inserts it into the target's named container — one procedure performing the
# two membership primitives (Core §2). Placement, movement. Where the entity being
# moved is the target, the request is routed to its specific-purpose procedure instead —
# DrawProcedure, BuryProcedure — each applying this body with the parameters it computed
# and the request already in its hand (§7's applied entrance).
#
# As T2 records it: at this scope no arrival event exists — a move produces no event
# yet (a fact event exists only where content cares, Mutation §8); when one enters, the
# move stamps its origin and destination housing on it as NameEventData, roles `origin`
# and `destination` (Core §2).


static func resolve(request: MoveRequest) -> Array[Event]:
	return apply(request.target, request.container_name, request.cargo, request)


static func apply(destination_owner: GameEntity, container_name: StringName,
		cargo: GameEntity, _context: EngineRequest) -> Array[Event]:
	var origin: EntityContainer = cargo.housing
	if origin == null:
		push_error("MoveProcedure: the cargo is unhoused — a move needs a housing to leave")
		return []
	var destination: EntityContainer = destination_owner.get_container(container_name)
	if destination == null:
		return []
	WriteAuthority.remove(origin, cargo)
	WriteAuthority.insert(destination, cargo)
	if destination.name == &"slotted_unit" and origin.name != &"slotted_unit":
		cargo.world.outlet.cue(&"card_placed", cargo, 0.0)   # its cue at commit (MSD s10)
	return []
