class_name CandidateMoves
extends RefCounted

# Candidate enumeration for the enemy engine — one generator per action kind (design
# Part 5). Day one: placements. Move / spell / ability generators land here as the slice
# widens; adding one must touch nothing in scoring or selection (the extension test).
#
# A candidate is plain data:
#   { "kind": "place", "inst": CardInstance, "row": int, "col": int, "cost": int }
# `inst` is the identity of the thing being played (a hand card for placements), carried
# through so the chosen candidate maps back to an executable action.


# Every legal placement: each affordable non-king unit in the pool × each empty own slot.
static func placements(state: BoardState, pool: Array, mana: int) -> Array:
	var out: Array = []
	for inst: CardInstance in pool:
		if inst.is_spell or inst.data.is_king:
			continue
		var cost: int = inst.get_attribute("cost")
		if cost > mana:
			continue
		for slot: Array in state.empty_slots(1):
			out.append({"kind": "place", "inst": inst,
					"row": slot[0], "col": slot[1], "cost": cost})
	return out
