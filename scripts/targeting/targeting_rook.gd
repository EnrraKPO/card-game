class_name TargetingRook
extends TargetingStrategy

# Locks onto the tankiest enemy — focuses the highest-HP unit.
# Distance is used as a tiebreaker when HP is equal.
func find_target(attacker: CardInstance, opponent_board: Array) -> CardInstance:
	var all := sorted_by_dist(attacker, opponent_board)
	if all.is_empty():
		return null
	all.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		if a.current_health != b.current_health:
			return a.current_health > b.current_health
		return dist(attacker, a.row, a.col) < dist(attacker, b.row, b.col)
	)
	return all[0]
