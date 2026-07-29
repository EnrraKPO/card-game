class_name CandidateMoves
extends RefCounted

# Candidate enumeration for the enemy engine — one generator per action kind (design
# Part 5): all four of decision 12's actions now have one. Adding a generator must touch
# nothing in scoring or selection (the extension test).
#
# A candidate is plain data:
#   { "kind": "place",   "inst": CardInstance, "row": int, "col": int, "cost": int }
#   { "kind": "move",    "inst": CardInstance, "from_row": int, "from_col": int,
#     "row": int, "col": int, "cost": 0 }
#   { "kind": "cast",    "inst": CardInstance(spell), "target": CardInstance|null, "cost": int }
#   { "kind": "ability", "inst": CardInstance(holder), "ability": AbilityData,
#     "target": CardInstance|null, "cost": int }
# `inst` is the identity of the thing being played (a hand card for placements/casts, the
# standing unit for moves/abilities), carried through so the chosen candidate maps back to
# an executable action. `target` is likewise an identity token — the apply seam re-finds
# the unit inside the simulated copy.
#
# LEGALITY lives here and only here: a candidate exists iff the play is legal right now
# (affordable, slot empty, tap available) AND the sim can evaluate it (CandidateApply.
# can_simulate_cast — a short deny-list now that simulations run the real rules).


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


# Every legal spell cast: each affordable, simulatable spell card in the pool — a manual
# spell tested against every fielded unit on either side (decision 17: every possible
# target; nonsense targets score as non-improvements and die in selection, which is
# exactly where "don't heal the player" is supposed to be decided).
static func spells(state: BoardState, pool: Array, mana: int) -> Array:
	var out: Array = []
	for inst: CardInstance in pool:
		if not inst.is_spell:
			continue
		var cost: int = inst.get_attribute("cost")
		if cost > mana or not CandidateApply.can_simulate_cast(inst.data.effects):
			continue
		for target: CardInstance in _targets_for(state, inst.data.effects):
			out.append({"kind": "cast", "inst": inst, "target": target, "cost": cost})
	return out


# Every legal ability activation: each fielded unit × each of its abilities, gated the
# way the live game gates the player (AbilityData.usable_by: mana + an unspent tap) —
# the sim state carries `exhausted`, so a tap spent earlier in this planned turn (or a
# unit that already acted) closes the window naturally.
static func abilities(state: BoardState, mana: int) -> Array:
	var out: Array = []
	for u: BoardState.UnitState in state.units(1):
		for ab_id: String in u.ability_ids:
			var ab := AbilityData.get_ability(ab_id)
			if ab == null or ab.mana > mana:
				continue
			if ab.tap and u.exhausted:
				continue
			if not ab.material.is_empty():
				continue   # material delivery = the spawn-half path; no sim story yet
			if ab.mana == 0 and not ab.tap:
				continue   # free + untapped = unbounded repeats; refuse until a cadence rule exists
			if not CandidateApply.can_simulate_cast(ab.effects):
				continue
			for target: CardInstance in _targets_for(state, ab.effects):
				out.append({"kind": "ability", "inst": u.source, "ability": ab,
						"target": target, "cost": ab.mana})
	return out


# The target axis of a cast's candidates: every fielded unit for a manual cast, the single
# no-target candidate otherwise (area/self casts carry their own targeting).
static func _targets_for(state: BoardState, effects: Array) -> Array:
	if not CandidateApply.needs_manual(effects):
		return [null]
	var out: Array = []
	for side in 2:
		for u: BoardState.UnitState in state.units(side):
			out.append(u.source)
	return out
