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
		var da := dist(attacker, a.row, a.col)
		var db := dist(attacker, b.row, b.col)
		if da != db:
			return da < db
		# deterministic tie-break — sort_custom is NOT stable, and an arbitrary pick
		# between equally-near targets read as a targeting rule to the player
		if a.row != b.row:
			return a.row < b.row
		return a.col < b.col
	)
	return candidates


# Geometric board distance between attacker and a cell (r, c) on the opponent board.
# Smaller = closer. COLUMN DEPTH DOMINATES: a target in a nearer column always beats
# any target in a farther one; the lane offset (mirrored row convention — both halves
# share visual lanes) only orders targets within the same column, facing lane first.
# (The old equal-weight sum let a same-lane unit two columns deep TIE an adjacent-lane
# front unit, and the unstable sort then picked arbitrarily — units appeared to
# prioritize their own row over the closest column.)
func dist(attacker: CardInstance, r: int, c: int) -> int:
	var lane_offset: int = abs(attacker.row + r - (BoardData.ROWS - 1))
	var depth: int
	if attacker.owner == 0:
		depth = BoardData.COLS + c - attacker.col
	else:
		depth = BoardData.COLS + attacker.col - c
	# lane_offset < ROWS, so scaling depth by ROWS makes the comparison lexicographic
	return depth * BoardData.ROWS + lane_offset


# True when attacker and target are in the same visual row (directly facing each other).
func is_facing(attacker: CardInstance, target: CardInstance) -> bool:
	return attacker.row + target.row == BoardData.ROWS - 1
