class_name OccasionsTargetDecision
extends Decision

# The occasion's target (Core §4): the stock derivation — it takes the target
# carried in the occasion's core as its own, kept to the narrowed field. Deterministic.


func resolve(plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	var elected: Array[GameEntity] = []
	if plate.occasion.target != null and candidates.has(plate.occasion.target):
		elected.append(plate.occasion.target)
	return elected
