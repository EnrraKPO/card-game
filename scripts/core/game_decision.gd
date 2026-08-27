class_name GameDecision
extends Decision

# Machinery only, never authored: automatic targeting of the Game — the Card type's
# play-targeting fact (Core §5). The no-targeting fallback is the AutoResolver (Core §4).


func resolve(plate: Plate, _candidates: Array[GameEntity]) -> Array[GameEntity]:
	var elected: Array[GameEntity] = [plate.world().game]
	return elected
