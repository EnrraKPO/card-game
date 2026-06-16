class_name TargetingStrategy
extends RefCounted

# Entry point. Override in subclasses to change how a unit picks its target.
# opponent_board: the 2D grid (Array[Array[CardInstance|null]]) belonging to the enemy.
func find_target(attacker: CardInstance, opponent_board: Array) -> CardInstance:
	var sorted := sorted_by_dist(attacker, opponent_board)
	return sorted[0] if not sorted.is_empty() else null


# ── Shared utilities available to all subclasses ───────────────────────────────

# Returns all non-null units in opponent_board sorted nearest-first.
func sorted_by_dist(attacker: CardInstance, opponent_board: Array) -> Array:
	var candidates: Array = []
	for r in range(opponent_board.size()):
		var row: Array = opponent_board[r]
		for c in range(row.size()):
			var inst: CardInstance = row[c]
			if inst != null:
				candidates.append(inst)
	candidates.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		return dist(attacker, a.row, a.col) < dist(attacker, b.row, b.col)
	)
	return candidates


# Geometric board distance between attacker and a cell (r, c) on the opponent board.
# Smaller = closer. Uses the mirrored row convention (both boards share row 0 = back).
func dist(attacker: CardInstance, r: int, c: int) -> int:
	var d: int = abs(attacker.row + r - (BoardData.ROWS - 1))
	if attacker.owner == 0:
		d += BoardData.COLS + c - attacker.col
	else:
		d += BoardData.COLS + attacker.col - c
	return d


# True when attacker and target are in the same visual row (directly facing each other).
func is_facing(attacker: CardInstance, target: CardInstance) -> bool:
	return attacker.row + target.row == BoardData.ROWS - 1
