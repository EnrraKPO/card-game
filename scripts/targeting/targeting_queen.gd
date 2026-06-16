class_name TargetingQueen
extends TargetingStrategy

# Neutralises the greatest threat — always attacks the highest-ATK enemy.
# Distance is used as a tiebreaker when ATK is equal.
func find_target(attacker: CardInstance, opponent_board: Array) -> CardInstance:
	var all := sorted_by_dist(attacker, opponent_board)
	if all.is_empty():
		return null
	all.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var aa := a.get_attribute("attack")
		var ba := b.get_attribute("attack")
		if aa != ba:
			return aa > ba
		return dist(attacker, a.row, a.col) < dist(attacker, b.row, b.col)
	)
	return all[0]
