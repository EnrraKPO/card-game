class_name NearestDecision
extends Decision

# Nearest (Core §4): ranks by the symmetric distance (Core §3) from the holder's
# standing, electing the single nearest candidate. Deterministic — the election is the
# resolution. A candidate standing nowhere cannot be ranked and falls out; a holder
# standing nowhere reaches nobody. Ties break by the candidate's address in reading
# order (B22).


func resolve(plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	var from: Vector3i = TargetResolver.standing_address(plate.holder)
	var elected: Array[GameEntity] = []
	if from.x < 0:
		return elected
	var best: GameEntity = null
	var best_key := Vector2i.MAX
	for candidate: GameEntity in candidates:
		var address: Vector3i = TargetResolver.standing_address(candidate)
		if address.x < 0:
			continue
		var key := Vector2i(BoardGeometry.distance(from, address), _reading_rank(address))
		if best == null or key < best_key:
			best = candidate
			best_key = key
	if best != null:
		elected.append(best)
	return elected


static func _reading_rank(address: Vector3i) -> int:
	return (address.x * BoardGeometry.ROWS + address.y) * BoardGeometry.COLS + address.z
