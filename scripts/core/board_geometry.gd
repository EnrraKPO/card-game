class_name BoardGeometry
extends RefCounted

# The geometry class (Core System Design §3): pure static
# functions — stateless; coordinates and the halves' facing relation in, coordinates out.
# All mirroring arithmetic between the two halves lives in this class ALONE.
#
# The address form (BRIEFS.html B7): Vector3i(side, row, col) — side is the half index
# (0 = player half, 1 = enemy half, matching the sides container's order), row and column
# are the slot's coordinate within its half. The board's shape is a fact of this class:
# ROWS × COLS per half, two halves.
#
# The facing relation, fixed here: the halves face each other — rows mirror (two cells
# share a lane when their rows sum to ROWS - 1), and columns run toward the battle line
# on the player half and away from it on the enemy half. `_depth` and `_lane` map an
# address into the one continuous space distance is measured in: player col 0..COLS-1 →
# depth 0..COLS-1, enemy col 0..COLS-1 → depth COLS..2·COLS-1 — player's last column and
# enemy's column 0 are adjacent, exactly where the two armies meet.

const SIDES := 2
const ROWS := 3
const COLS := 4


static func is_real(address: Vector3i) -> bool:
	return address.x >= 0 and address.x < SIDES \
			and address.y >= 0 and address.y < ROWS \
			and address.z >= 0 and address.z < COLS


# Every real address, in fixed reading order (side, then row, then column) — deterministic
# so every re-run reproduces its results exactly.
static func all_addresses() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for s: int in SIDES:
		for r: int in ROWS:
			for c: int in COLS:
				out.append(Vector3i(s, r, c))
	return out


static func _depth(address: Vector3i) -> int:
	return address.z if address.x == 0 else COLS + address.z


static func _lane(address: Vector3i) -> int:
	return address.y if address.x == 0 else ROWS - 1 - address.y


# ── Symmetric distance ─────────────────────────────────────────────────────────────────
# Two coordinates in (§3). Symmetric: distance(a, b) == distance(b, a), whichever halves
# they stand on. Measured in cells through the unified depth/lane space.
static func distance(a: Vector3i, b: Vector3i) -> int:
	return absi(_depth(a) - _depth(b)) + absi(_lane(a) - _lane(b))


# ── The attack-preference comparator ───────────────────────────────────────────────────
# The attack targeting ordering (§3), with the facing relation as an input — the facing
# is read from the attacker's half. Returns a score: lower is preferred. Column depth
# dominates — a target in a nearer column always beats any target in a farther one — and
# the mirrored lane offset only orders targets within the same column, facing lane first.
# Acceptance standard: reproduces the current game's orderings — this is bit-identical to
# the pre-nuke attack_dist over its domain, an attacker and a target on opposite halves.
static func attack_preference(from: Vector3i, to: Vector3i) -> int:
	var lane_offset: int = absi(_lane(from) - _lane(to))
	var facing: int = 1 if from.x == 0 else -1
	var depth: int = (_depth(to) - _depth(from)) * facing
	# lane_offset < ROWS, so scaling depth by ROWS makes the comparison lexicographic.
	return depth * ROWS + lane_offset


# ── AOE shapes (§3) ────────────────────────────────────────────────────────────────────
# Shape definitions are BRIEFS.html B8. Every shape yields addresses in fixed reading
# order; the caller fetches slots through the BoardManager and reads occupancy through
# each slot's container (§3).

# Row: every cell of the origin's half sharing the origin's row.
static func row_cells(origin: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c: int in COLS:
		out.append(Vector3i(origin.x, origin.y, c))
	return out


# Column: every cell of the origin's half sharing the origin's column.
static func column_cells(origin: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for r: int in ROWS:
		out.append(Vector3i(origin.x, r, origin.z))
	return out


# Radius: every cell within `radius` of the origin by the symmetric distance, both halves,
# the origin included at distance zero.
static func radius_cells(origin: Vector3i, radius: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for address: Vector3i in all_addresses():
		if distance(origin, address) <= radius:
			out.append(address)
	return out


# Square: every cell within `radius` of the origin on BOTH axes of the unified space —
# Chebyshev distance over depth and lane — the origin included.
static func square_cells(origin: Vector3i, radius: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for address: Vector3i in all_addresses():
		var dd: int = absi(_depth(origin) - _depth(address))
		var dl: int = absi(_lane(origin) - _lane(address))
		if maxi(dd, dl) <= radius:
			out.append(address)
	return out


# Cone: spreads from the origin toward the facing half — at each forward step d (1..reach)
# it holds the cells d columns ahead of the origin whose lane offset is at most d. The
# origin itself is not in its own cone.
static func cone_cells(origin: Vector3i, reach: int) -> Array[Vector3i]:
	var facing: int = 1 if origin.x == 0 else -1
	var out: Array[Vector3i] = []
	for address: Vector3i in all_addresses():
		var d: int = (_depth(address) - _depth(origin)) * facing
		if d >= 1 and d <= reach and absi(_lane(address) - _lane(origin)) <= d:
			out.append(address)
	return out
