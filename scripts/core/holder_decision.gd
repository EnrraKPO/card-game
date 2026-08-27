class_name HolderDecision
extends Decision

# Machinery only, never authored: elects the plate's holder — the spell burial's
# resolver, fixed in its machinery (Core §6). Deterministic.


func resolve(plate: Plate, _candidates: Array[GameEntity]) -> Array[GameEntity]:
	var elected: Array[GameEntity] = [plate.holder]
	return elected
