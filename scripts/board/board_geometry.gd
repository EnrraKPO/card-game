class_name BoardGeometry
extends RefCounted

# COORDINATES IN, COORDINATES OUT (LOCATION_MANAGER_DESIGN.md §4.4). Pure functions with no
# knowledge that any *thing* exists — no units, no slots, no manager, no world. Geometry
# yields locations; the caller asks the façade what is there and applies its own conditions.
#
# PREDICATES NEVER ENTER HERE. That fence is what keeps this from re-growing into the third
# proximity implementation: the moment geometry can be told "…that is empty" or "…that is an
# enemy", every caller starts teaching it a new condition.
#
# NO FLOOD FILL. An expanding search is only needed when nearness depends on REACHABILITY —
# when something can stand in the way. Nothing obstructs anything on this board (§7), so
# distance is a formula and sort-by-distance answers "nearest" exactly. At twelve cells a
# side, any performance argument for something cleverer is imaginary.
#
# DISTANCE IS NOT PREFERENCE (§2.10). What lives here is a real distance: symmetric, with no
# notion of "forward". The attack-targeting *preference ordering* ("column depth dominates,
# lane offset breaks ties") is a GAME RULE, not a distance — it lived in the targeting layer
# and must return with it (targeting-cleanup demolition), never migrate in here.

# ── The unified reading of the two mirrored halves ──────────────────────────────────────
# The halves face each other: rows are mirrored (units are opposite when their rows SUM to
# ROWS - 1), and columns run toward the battle line on the player half and away from it on
# the enemy half. Distance needs one continuous space to be measured in, so these two map an
# address into it — INTERNALLY. Unifying the public address space is explicitly parked (§7);
# this is the internals that parking said it could change without touching the interface.
#
# depth: player col 0..3 -> 0..3, enemy col 0..3 -> 4..7. Player col 3 and enemy col 0 are
# therefore adjacent (depth 3 and 4), which is exactly where the two armies meet.
static func _depth(loc: BoardLocation) -> int:
	return loc.col if loc.side == 0 else BoardData.COLS + loc.col


# lane: the shared visual row. Enemy rows count the other way, so both halves index the same
# three lanes and "directly facing" is simply "same lane".
static func _lane(loc: BoardLocation) -> int:
	return loc.row if loc.side == 0 else BoardData.ROWS - 1 - loc.row


# Symmetric board distance between two cells, in cells. distance(a, b) == distance(b, a),
# always, whichever halves they are on.
static func distance(a: BoardLocation, b: BoardLocation) -> int:
	if a == null or b == null:
		return -1
	return absi(_depth(a) - _depth(b)) + absi(_lane(a) - _lane(b))


# Every cell on the board ordered nearest-first from `origin` (the origin itself comes first,
# at distance 0). Ties break in reading order, so the list is identical on every re-run.
#
# This is the ONE search primitive: "nearest empty", "nearest anything", "the ring around
# here" are all this list, walked by a caller that asks what is at each address and stops when
# its own condition is satisfied.
static func cells_by_distance(origin: BoardLocation) -> Array:
	if origin == null:
		return []
	var out: Array = BoardLocation.all()
	out.sort_custom(func(a: BoardLocation, b: BoardLocation) -> bool:
		var da := distance(origin, a)
		var db := distance(origin, b)
		if da != db:
			return da < db
		var ka := a.key()
		var kb := b.key()
		if ka.x != kb.x:
			return ka.x < kb.x
		if ka.y != kb.y:
			return ka.y < kb.y
		return ka.z < kb.z)
	return out


# The cells one step away — orthogonal neighbours, INCLUDING across the battle line where the
# two halves touch. Whether the line is a wall is a RULE, not geometry: the caller filters.
# Reading order, as everything here.
static func neighbours(origin: BoardLocation) -> Array:
	var out: Array = []
	for loc: BoardLocation in BoardLocation.all():
		if distance(origin, loc) == 1:
			out.append(loc)
	return out


# True when the two cells share a visual lane — the "directly facing each other" test; the
# lane convention has one owner, here.
static func same_lane(a: BoardLocation, b: BoardLocation) -> bool:
	if a == null or b == null:
		return false
	return _lane(a) == _lane(b)
