class_name TargetingKnight
extends TargetingStrategy

# Mimics a chess knight's jump: prefers to leap over the frontmost occupied
# enemy column, then among what's left prefers landing outside its own row.
# Each preference is only applied when it leaves at least one candidate —
# otherwise it falls back, eventually behaving as a plain nearest-target search.
func find_target(attacker: CardInstance, opponent_board: Array) -> CardInstance:
	var pool := sorted_by_dist(attacker, opponent_board)
	if pool.is_empty():
		return null

	var front_col: int = _frontmost_col(attacker, opponent_board)
	var behind: Array = pool.filter(func(t: CardInstance) -> bool: return t.col != front_col)
	if not behind.is_empty():
		pool = behind

	var off_row: Array = pool.filter(func(t: CardInstance) -> bool: return not is_facing(attacker, t))
	if not off_row.is_empty():
		pool = off_row

	return pool[0]


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
