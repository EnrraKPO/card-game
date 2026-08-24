class_name GameDecision
extends Decision

# Machinery only, never authored: the default fixed at construction for an effect
# authored without a resolver — it targets the Game (Core §4).


func resolve(plate: Plate, _candidates: Array[GameEntity]) -> Array[GameEntity]:
	var elected: Array[GameEntity] = [plate.world().game]
	return elected
