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


# Every legal TWO-MOVE arrangement: unordered pairs of movable units × target column
# combinations, emitted as ONE candidate holding both moves (user-designed 2026-07-31 —
# the reshuffle pass). The point is escaping single-step neutrality: "king forward" alone
# improves nothing and dies at the must-improve gate, but "king forward AND fodder into
# the opened column" is a strictly better BOARD — so the pair is scored as one
# destination, gated as a whole, and the greedy loop chains deeper reshuffles across
# picks (each accepted pair frees geometry the next pick can see). Single moves stay
# moves(); this generator emits pairs only.
#
# Columns, not slots, on purpose: every eval is lane-blind (exposure v2), so two
# arrangements differing only in rows score identically — enumerating rows would
# multiply the cohort by 9 to distinguish nothing. Each pair is emitted only if it is
# EXECUTABLE in some order under live rules (one move per unit per turn, a free slot at
# each step — a swap between two full columns has no legal order and is not a
# candidate); concrete rows are resolved here, at enumeration, so the candidate maps
# straight to two executable move actions.
static func arrangements(state: BoardState, moved: Dictionary) -> Array:
	var movers: Array = []
	for u: BoardState.UnitState in state.units(1):
		if not u.is_building and not moved.has(u.source):
			movers.append(u)
	var out: Array = []
	for i in movers.size():
		for j in range(i + 1, movers.size()):
			for ca in BoardData.COLS:
				for cb in BoardData.COLS:
					var pair := _feasible_pair(state, movers[i], movers[j], ca, cb)
					if not pair.is_empty():
						out.append(pair)
	return out


# One pair, made concrete: try a-then-b, then b-then-a; the first order with a free row
# at every step wins. Returns {} when the pair is a no-op (neither unit changes column)
# or neither order is executable.
static func _feasible_pair(state: BoardState, a: BoardState.UnitState,
		b: BoardState.UnitState, ca: int, cb: int) -> Dictionary:
	if ca == a.col and cb == b.col:
		return {}   # nobody changes column — not an arrangement
	if ca == a.col or cb == b.col:
		return {}   # one mover is a no-op — that pair IS the single move, already enumerated
	for order: Array in [[a, ca, b, cb], [b, cb, a, ca]]:
		var first: BoardState.UnitState = order[0]
		var second: BoardState.UnitState = order[2]
		var free := _free_rows(state)
		var r1 := _take_row(free, int(order[1]))
		if r1 < 0:
			continue
		free[first.col].append(first.row)   # the first mover's seat opens behind it
		var r2 := _take_row(free, int(order[3]))
		if r2 < 0:
			continue
		return {"kind": "arrange", "cost": 0, "moves": [
			{"inst": first.source, "from_row": first.row, "from_col": first.col,
					"row": r1, "col": int(order[1])},
			{"inst": second.source, "from_row": second.row, "from_col": second.col,
					"row": r2, "col": int(order[3])}]}
	return {}


# col → the free row indices in that column of the OWN grid, lowest first.
static func _free_rows(state: BoardState) -> Dictionary:
	var free: Dictionary = {}
	for c in BoardData.COLS:
		free[c] = []
	for slot: Array in state.empty_slots(1):
		(free[slot[1]] as Array).append(slot[0])
	return free


# Pops the first free row of the column; -1 when the column is full.
static func _take_row(free: Dictionary, col: int) -> int:
	var rows: Array = free[col]
	if rows.is_empty():
		return -1
	return int(rows.pop_front())


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


# The target axis of a cast's candidates. TARGETING REMOVED (targeting-cleanup demolition):
# unreachable while can_simulate_cast refuses everything. NEEDS: every fielded unit (both
# sides) as one candidate each for a manual cast — the gesture requirement asked of the
# targeting authority — and the single no-target candidate otherwise (area/self casts carry
# their own targeting).
static func _targets_for(_state: BoardState, _effects: Array) -> Array:
	return [null]
