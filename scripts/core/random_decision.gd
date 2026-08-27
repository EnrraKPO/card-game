class_name RandomDecision
extends Decision

# Random (Kind Rosters §2): elects one candidate uniformly. The roll is an unknown — it settles
# at engagement, drawn from the world's seeded rng; resolve answers the eligible field,
# undecided.


func engage(plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	@warning_ignore("redundant_await")
	await null
	var elected: Array[GameEntity] = []
	if candidates.is_empty():
		return elected
	elected.append(candidates[plate.world().rng.randi_range(0, candidates.size() - 1)])
	return elected
