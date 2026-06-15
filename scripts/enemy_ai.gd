class_name EnemyAI
extends RefCounted

# Base implementation: shuffle hand and fill random empty slots.
# Override decide_placements in a subclass for distinct encounter behaviour.
func decide_placements(hand: Array, grid: Array, mana: int) -> Array:
	var empty_slots: Array = []
	for r in grid.size():
		for c in grid[r].size():
			if grid[r][c] == null:
				empty_slots.append([r, c])
	empty_slots.shuffle()

	var shuffled: Array = hand.duplicate()
	shuffled.shuffle()

	var remaining := mana
	var placements: Array = []
	for inst: CardInstance in shuffled:
		if empty_slots.is_empty():
			break
		if inst.data.cost <= remaining:
			var pos: Array = empty_slots.pop_front()
			placements.append({ "inst": inst, "row": pos[0], "col": pos[1] })
			remaining -= inst.data.cost
	return placements
