class_name BoardFacade
extends RefCounted

# THE ONE THING THAT SPEAKS BOTH LANGUAGES (LOCATION_MANAGER_DESIGN.md §4.3). The manager
# hands back something it only knows as "a docked thing"; this knows that the piece layer
# yields units and the ground layer yields slots, and hands back the real object.
#
# TYPE KNOWLEDGE LIVES HERE AND NOWHERE ELSE. Callers never cast. A third layer would only
# teach this file — every other call site would be untouched, which is the whole point of
# having a façade instead of the codebase's older pattern (a write target typed as Object,
# with every dispatcher branching on what it turns out to be).
#
# Static, taking the world it reads. The manager is not reachable any other way — see §4.2
# on why it is not a global and why dockables hold no back-reference to it.

# The layer tags. The dockables declare them (CardInstance.dock_layer, BoardSlot.dock_layer);
# these are the same strings, named once for callers that need to say which layer they mean.
# They live HERE and not on the manager on purpose: the manager files by an opaque tag and
# must never hold a list of the layers that exist.
const PIECES := &"pieces"
const GROUND := &"ground"


# ── Where is this thing ─────────────────────────────────────────────────────────────────

# The location of any dockable — a unit, a slot, anything the board carries. Null = it is not
# on the board: a card in hand, an ability's tray token, a unit that has been retired.
static func location_of(world: CombatWorld, dockable: Object) -> BoardLocation:
	if world == null:
		return null
	return world.locations.location_of(dockable)


static func is_on_board(world: CombatWorld, dockable: Object) -> bool:
	return location_of(world, dockable) != null


# ── What is at this location ────────────────────────────────────────────────────────────

# The unit standing at an address, or null. Null covers both "empty cell" and "not a cell" —
# the caller decides which of those it cares about (§2.9).
static func unit_at(world: CombatWorld, loc: BoardLocation) -> CardInstance:
	if world == null or loc == null:
		return null
	return world.locations.at(loc, PIECES) as CardInstance


# The ground at an address. ALWAYS answers for a real cell: the ground exists everywhere, and
# a slot being allocated on first touch is an invisible implementation detail. Null only for
# a null/unreal address.
static func slot_at(world: CombatWorld, loc: BoardLocation) -> BoardSlot:
	if world == null or loc == null:
		return null
	var existing: BoardSlot = world.locations.at(loc, GROUND) as BoardSlot
	if existing != null:
		return existing
	var fresh := BoardSlot.new()
	world.locations.dock(fresh, loc)
	return fresh


# Read-only ground lookup for PRESENTATION: null for ground nothing has ever touched, so a
# render pass over the whole board doesn't allocate 24 slots that carry nothing. Rules paths
# use slot_at, which always answers.
static func peek_slot(world: CombatWorld, loc: BoardLocation) -> BoardSlot:
	if world == null or loc == null:
		return null
	return world.locations.at(loc, GROUND) as BoardSlot


# ── Enumeration ─────────────────────────────────────────────────────────────────────────

# Every unit on the board, in THE board's declared reading order: row-major, the player's
# cell before the enemy's at each address. Fixed, and preserved from before the manager
# existed — simulations re-run and must reproduce results exactly, and a re-ordering here
# would be invisible right up until it changed a fight.
static func units(world: CombatWorld) -> Array:
	if world == null:
		return []
	var out: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p := unit_at(world, BoardLocation.at(0, r, c))
			if p != null:
				out.append(p)
			var e := unit_at(world, BoardLocation.at(1, r, c))
			if e != null:
				out.append(e)
	return out


# Every unit on one half of the board, in reading order. SPATIAL — this is who is standing on
# that side, not who fights for it. Allegiance is a separate question with a separate answer
# (CardInstance.owner); conflating the two is the defect this initiative exists to make hard
# to write (§3).
static func units_on_side(world: CombatWorld, side: int) -> Array:
	var out: Array = []
	for unit: CardInstance in units(world):
		var loc := location_of(world, unit)
		if loc != null and loc.side == side:
			out.append(unit)
	return out


# Slots that currently carry statuses, in fixed address order. Expired-but-unfiled statuses
# don't count as activity (pull validity — see StatusEngine.is_expired).
static func active_slots(world: CombatWorld) -> Array:
	if world == null:
		return []
	var out: Array = []
	for slot: BoardSlot in world.locations.docked(GROUND):
		if not slot.statuses.is_empty():
			out.append(slot)
	return out


# ── Geometry, applied ───────────────────────────────────────────────────────────────────

# The nearest cell to `origin` with nobody standing on it, restricted to one half of the
# board. Null = that half is full. Geometry orders the cells; the emptiness condition is
# applied HERE, by the caller side of the fence — geometry never sees a predicate (§4.4).
static func nearest_empty(world: CombatWorld, origin: BoardLocation, side: int) -> BoardLocation:
	for loc: BoardLocation in LegacyBoardGeometry.cells_by_distance(origin):
		if loc.side != side:
			continue
		if unit_at(world, loc) == null:
			return loc
	return null
