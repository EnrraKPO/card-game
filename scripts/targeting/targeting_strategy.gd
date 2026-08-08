class_name TargetingStrategy
extends RefCounted

# How a unit picks who to hit. Handed a PLACEMENT — the LocationManager holding who stands
# where — rather than a grid array, because "the same units in a different arrangement" is a
# question the game asks constantly: the board's landing preview asks it on every hover
# (CombatBoard's declared preview world), and it is answered by handing over a different
# placement, not by moving anything.
#
# THE PREFERENCE ORDERING BELOW IS A GAME RULE, NOT A DISTANCE (LOCATION_MANAGER_DESIGN.md
# §2.10). `dist` is the ordering "column depth dominates, lane offset breaks ties" wearing a
# distance's clothes, and it stays exactly as it was — who attacks whom must not move.
# BoardGeometry.distance is the real, symmetric distance, and is deliberately NOT used here.
#
# The candidate pool is the units standing on the OPPOSITE HALF of the board. That is a
# spatial reading, and always was: the old code picked "the grid that isn't mine", and a grid
# is a half.


# Entry point. Override in subclasses to change how a unit picks its target.
func find_target(places: LocationManager, attacker: CardInstance) -> CardInstance:
	var sorted := sorted_by_dist(places, attacker)
	return sorted[0] if not sorted.is_empty() else null


# ── Shared utilities available to all subclasses ───────────────────────────────

# Every unit on the half opposite the attacker, sorted nearest-first by the preference above.
func sorted_by_dist(places: LocationManager, attacker: CardInstance) -> Array:
	var from := places.location_of(attacker)
	if from == null:
		return []   # an attacker that stands nowhere reaches nobody
	var candidates: Array = candidates_for(places, attacker)
	candidates.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var la := places.location_of(a)
		var lb := places.location_of(b)
		var da := dist(from, la)
		var db := dist(from, lb)
		if da != db:
			return da < db
		# deterministic tie-break — sort_custom is NOT stable, and an arbitrary pick
		# between equally-near targets read as a targeting rule to the player
		if la.row != lb.row:
			return la.row < lb.row
		return la.col < lb.col
	)
	return candidates


# The pool, unsorted but in fixed reading order: whoever stands on the other half.
func candidates_for(places: LocationManager, attacker: CardInstance) -> Array:
	var from := places.location_of(attacker)
	if from == null:
		return []
	var out: Array = []
	for unit: CardInstance in places.docked(BoardFacade.PIECES):
		var loc := places.location_of(unit)
		if loc != null and loc.side != from.side:
			out.append(unit)
	return out


# Where a unit stands under this placement — the one lookup subclasses need, kept short
# because their comparators read it twice per compare.
func at(places: LocationManager, unit: CardInstance) -> BoardLocation:
	return places.location_of(unit)


# The attacker's PREFERENCE ordering over cells. Smaller = preferred. COLUMN DEPTH DOMINATES:
# a target in a nearer column always beats any target in a farther one; the lane offset
# (mirrored row convention — both halves share visual lanes) only orders targets within the
# same column, facing lane first.
# (The old equal-weight sum let a same-lane unit two columns deep TIE an adjacent-lane
# front unit, and the unstable sort then picked arbitrarily — units appeared to
# prioritize their own row over the closest column.)
#
# Kept bit-identical through the location refactor, deliberately: this is the most playtested
# behaviour in the game, and the consolidation was not permitted to nudge it.
func dist(from: BoardLocation, to: BoardLocation) -> int:
	if from == null or to == null:
		return 1 << 30
	var lane_offset: int = absi(from.row + to.row - (BoardData.ROWS - 1))
	var depth: int
	if from.side == 0:
		depth = BoardData.COLS + to.col - from.col
	else:
		depth = BoardData.COLS + from.col - to.col
	# lane_offset < ROWS, so scaling depth by ROWS makes the comparison lexicographic
	return depth * BoardData.ROWS + lane_offset


# True when the two cells share a visual row (directly facing each other) — the lane
# convention, owned by geometry now.
func is_facing(from: BoardLocation, to: BoardLocation) -> bool:
	return BoardGeometry.same_lane(from, to)
