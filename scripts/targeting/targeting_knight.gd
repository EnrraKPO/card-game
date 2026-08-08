class_name TargetingKnight
extends TargetingStrategy

# Mimics a chess knight's jump: prefers to leap over the frontmost occupied
# enemy column, then among what's left prefers landing outside its own row.
# Each preference is only applied when it leaves at least one candidate —
# otherwise it falls back, eventually behaving as a plain nearest-target search.
func find_target(places: LocationManager, attacker: CardInstance) -> CardInstance:
	var pool := sorted_by_dist(places, attacker)
	if pool.is_empty():
		return null
	var from := at(places, attacker)

	var front_col: int = _frontmost_col(places, attacker)
	var behind: Array = pool.filter(func(t: CardInstance) -> bool:
			return at(places, t).col != front_col)
	if not behind.is_empty():
		pool = behind

	var off_row: Array = pool.filter(func(t: CardInstance) -> bool:
			return not is_facing(from, at(places, t)))
	if not off_row.is_empty():
		pool = off_row

	return pool[0]


# The column index of the frontmost occupied column on the defending half (-1 if it is
# empty). "Front" means closest to the attacker: lowest col when it stands on the player
# half, highest when it stands on the enemy half — the mirrored column convention.
func _frontmost_col(places: LocationManager, attacker: CardInstance) -> int:
	var from := at(places, attacker)
	if from == null:
		return -1
	var occupied: Array = []
	for t: CardInstance in candidates_for(places, attacker):
		var c: int = at(places, t).col
		if not occupied.has(c):
			occupied.append(c)
	if occupied.is_empty():
		return -1
	occupied.sort()
	return occupied[0] if from.side == 0 else occupied[occupied.size() - 1]
