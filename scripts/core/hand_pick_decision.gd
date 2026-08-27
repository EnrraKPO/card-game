class_name HandPickDecision
extends Decision

# Hand-pick (Kind Rosters §2): the decision consults the player. The pick is an unknown — it
# settles at engagement through the world's picker seam; resolve answers the eligible
# field, undecided. A declined pick yields an empty election, which ends the delivery —
# for an activated ask, the ask whole, unpaid.


func engage(plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	var elected: Array[GameEntity] = []
	if candidates.is_empty():
		return elected
	var picked: GameEntity = await plate.world().picker.pick(candidates, plate)
	if picked != null and not candidates.has(picked):
		push_error("HandPickDecision: the pick is outside the eligible field — declined")
		picked = null
	if picked != null:
		elected.append(picked)
	return elected
