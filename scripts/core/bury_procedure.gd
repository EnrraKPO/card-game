class_name BuryProcedure
extends EngineProcedure

# Resolves a burial (Core §6; Mutation System Design §7, A17): places the target in its
# side's graveyard. The move happening happens, so this procedure applies the
# MoveProcedure with the parameters it computed and the request already in its hand
# (§7's applied entrance).


static func resolve(request: BuryRequest) -> Array[Event]:
	var buried: GameEntity = request.target
	var side: Side = buried.allegiance
	if side == null:
		push_error("BuryProcedure: the target belongs to no side — no graveyard to reach")
		return []
	return MoveProcedure.apply(side, &"graveyard", buried, request)
