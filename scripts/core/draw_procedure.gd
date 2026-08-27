class_name DrawProcedure
extends EngineProcedure

# Resolves a draw (Mutation System Design §7): moves the target from its deck to
# its side's hand. The move happening happens, so this procedure applies the
# MoveProcedure with the parameters it computed and the request already in its hand
# (§7's applied entrance).


static func resolve(request: DrawRequest) -> Array[Event]:
	var card: GameEntity = request.target
	var housing: EntityContainer = card.housing
	if housing == null or housing.name != &"deck":
		push_error("DrawProcedure: the target stands in no deck — draw refused")
		return []
	var side: GameEntity = housing.owner
	return MoveProcedure.apply(side, &"hand", card, request)
