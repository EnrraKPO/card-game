class_name StatRankedDecision
extends Decision

# Stat-ranked (Core §4): ranks the candidates by a stat, electing the single highest or
# lowest bearer. Deterministic — ties break to the earliest candidate in the narrowed
# field's order (B22). A candidate not bearing the stat cannot be ranked and falls out.

var stat: StringName = &""
var rank: StringName = &"highest"


func resolve(_plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	var elected: Array[GameEntity] = []
	var best: GameEntity = null
	var best_value: float = 0.0
	for candidate: GameEntity in candidates:
		if not candidate.bears_stat(stat):
			continue
		var value: float = candidate.get_stat(stat)
		if best == null \
				or (rank == &"highest" and value > best_value) \
				or (rank == &"lowest" and value < best_value):
			best = candidate
			best_value = value
	if best != null:
		elected.append(best)
	return elected
