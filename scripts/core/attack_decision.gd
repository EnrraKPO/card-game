class_name AttackDecision
extends Decision

# The attack resolver's decision (Combat Frame §6; Core §3): ranks by
# BoardGeometry's attack-preference comparator from the holder's standing, electing one.
# Machinery — the main action's fixed targeting, never authored. Deterministic: ties
# break by the candidate's row then column, the pre-nuke ordering kept bit-identical.
# A candidate standing nowhere cannot be ranked and falls out; a holder standing
# nowhere reaches nobody.


func resolve(plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	var from: Vector3i = TargetResolver.standing_address(plate.holder)
	var elected: Array[GameEntity] = []
	if from.x < 0:
		return elected
	var best: GameEntity = null
	var best_key := Vector3i.MAX
	for candidate: GameEntity in candidates:
		var address: Vector3i = TargetResolver.standing_address(candidate)
		if address.x < 0:
			continue
		var key := Vector3i(BoardGeometry.attack_preference(from, address), address.y, address.z)
		if best == null or key < best_key:
			best = candidate
			best_key = key
	if best != null:
		elected.append(best)
	return elected
