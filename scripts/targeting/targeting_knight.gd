class_name TargetingKnight
extends TargetingStrategy

# Leaps over the entire frontmost occupied enemy column and strikes behind it.
# Falls back to the front column only when no targets exist further back.
func find_target(attacker: CardInstance, opponent_board: Array) -> CardInstance:
	var front_col: int = _frontmost_col(attacker, opponent_board)
	if front_col < 0:
		return null

	# Gather all units NOT in the front column.
	var behind: Array = []
	for r in range(opponent_board.size()):
		var row: Array = opponent_board[r]
		for c in range(row.size()):
			if c == front_col:
				continue
			var inst: CardInstance = row[c]
			if inst != null:
				behind.append(inst)

	if not behind.is_empty():
		behind.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
			return dist(attacker, a.row, a.col) < dist(attacker, b.row, b.col)
		)
		return behind[0]

	# No targets behind the front column — fall back to nearest available.
	return sorted_by_dist(attacker, opponent_board)[0]


# Returns the column index of the frontmost occupied column (-1 if board is empty).
# "Front" means closest to the attacker: lowest col for player, highest col for enemy.
func _frontmost_col(attacker: CardInstance, opponent_board: Array) -> int:
	var occupied: Array = []
	for c in range(BoardData.COLS):
		for r in range(opponent_board.size()):
			var row: Array = opponent_board[r]
			var inst: CardInstance = row[c]
			if inst != null:
				occupied.append(c)
				break
	if occupied.is_empty():
		return -1
	occupied.sort()
	return occupied[0] if attacker.owner == 0 else occupied[occupied.size() - 1]
