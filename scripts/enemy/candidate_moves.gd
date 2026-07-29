class_name CandidateMoves
extends RefCounted

# Candidate enumeration for the enemy engine — one generator per action kind (design
# Part 5): placements and moves so far. Spell / ability generators land here as the slice
# widens; adding one must touch nothing in scoring or selection (the extension test).
#
# A candidate is plain data:
#   { "kind": "place", "inst": CardInstance, "row": int, "col": int, "cost": int }
#   { "kind": "move",  "inst": CardInstance, "from_row": int, "from_col": int,
#     "row": int, "col": int, "cost": 0 }
# `inst` is the identity of the thing being played (a hand card for placements, the
# standing unit for moves), carried through so the chosen candidate maps back to an
# executable action.


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


# Every legal repositioning: each own movable unit × each empty own slot. Buildings are
# rooted; the king is DELIBERATELY movable — Captain-as-tank is decision 15 running in
# reverse, and it only exists if the king can step forward. `moved` holds units already
# repositioned this turn (one move per unit per turn — keeps turns legible and, with the
# engine's must-improve gate, guarantees the planning loop terminates).
static func moves(state: BoardState, moved: Dictionary) -> Array:
	var out: Array = []
	for u: BoardState.UnitState in state.units(1):
		if u.is_building or moved.has(u.source):
			continue
		for slot: Array in state.empty_slots(1):
			out.append({"kind": "move", "inst": u.source,
					"from_row": u.row, "from_col": u.col,
					"row": slot[0], "col": slot[1], "cost": 0})
	return out
