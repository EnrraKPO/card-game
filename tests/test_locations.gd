extends TestCase

# The location layer's own contract (LOCATION_MANAGER_DESIGN.md §4.1/§4.2/§4.4): the address
# value, the manager's two questions, and pure geometry. Nothing here touches game rules —
# these are the properties the rest of the conversion is allowed to assume.

# A dockable that is nothing but a dockable. The manager's ignorance is the thing under test:
# it must file this exactly as it files a unit, knowing nothing about either.
class Probe extends RefCounted:
	var tag: StringName = &"probe"
	var name: String = ""
	func dock_layer() -> StringName:
		return tag


func suite_name() -> String:
	return "Locations"


func run() -> void:
	_location_value()
	_geometry_distance()
	_geometry_ordering()
	_manager_two_questions()
	_manager_collisions()
	_manager_layers()
	_manager_copy()


func _probe(p_name: String, layer: StringName = &"probe") -> Probe:
	var p := Probe.new()
	p.name = p_name
	p.tag = layer
	return p


# ── The address value ───────────────────────────────────────────────────────────────────

func _location_value() -> void:
	var a := BoardLocation.at(0, 1, 2)
	var b := BoardLocation.at(0, 1, 2)
	check(a == b, "the same address is the same object (interned)")
	check(a.same_as(b), "same_as agrees with identity")
	check(BoardLocation.at(0, 0, 0) != BoardLocation.at(1, 0, 0), "sides are distinct addresses")

	# Validity answered once, here — replacing four hand-rolled bounds guards.
	check_eq(BoardLocation.at(0, -1, 0), null, "negative row is not a cell")
	check_eq(BoardLocation.at(0, BoardData.ROWS, 0), null, "row past the board is not a cell")
	check_eq(BoardLocation.at(0, 0, BoardData.COLS), null, "col past the board is not a cell")
	check_eq(BoardLocation.at(2, 0, 0), null, "there is no third side")
	check(BoardLocation.is_real(1, BoardData.ROWS - 1, BoardData.COLS - 1), "the far corner is real")

	check_eq(BoardLocation.all().size(), BoardData.ROWS * BoardData.COLS * 2, "every cell, once")
	# Fixed reading order — simulations re-run and must reproduce results exactly.
	var all: Array = BoardLocation.all()
	check(all[0] == BoardLocation.at(0, 0, 0), "reading order starts at the player corner")
	check(all[all.size() - 1] == BoardLocation.at(1, BoardData.ROWS - 1, BoardData.COLS - 1),
			"reading order ends at the enemy corner")

	# A location can be a Dictionary key directly — the property interning buys.
	var d: Dictionary = {}
	d[BoardLocation.at(1, 2, 3)] = "here"
	check_eq(d.get(BoardLocation.at(1, 2, 3)), "here", "a location keys a Dictionary by value")


# ── Geometry ────────────────────────────────────────────────────────────────────────────

func _geometry_distance() -> void:
	var origin := BoardLocation.at(0, 0, 0)
	check_eq(BoardGeometry.distance(origin, origin), 0, "distance to itself is zero")

	# SYMMETRY is the whole point of separating distance from preference (§2.10): a real
	# distance has no notion of "forward", so it cannot depend on who is asking.
	for a: BoardLocation in BoardLocation.all():
		for b: BoardLocation in BoardLocation.all():
			if BoardGeometry.distance(a, b) != BoardGeometry.distance(b, a):
				check(false, "distance is symmetric for %s / %s" % [a, b])
				return
	check(true, "distance is symmetric across every pair of cells")

	# The two halves meet where the armies do: the player's front column is adjacent to the
	# enemy's front column, one step apart.
	var p_front := BoardLocation.at(0, 1, BoardData.COLS - 1)
	var e_front := BoardLocation.at(1, BoardData.ROWS - 1 - 1, 0)
	check_eq(BoardGeometry.distance(p_front, e_front), 1, "the front lines are adjacent")
	check(BoardGeometry.same_lane(p_front, e_front), "mirrored rows share a visual lane")
	check(not BoardGeometry.same_lane(p_front, BoardLocation.at(1, 0, 0)), "other lanes do not")

	# Within a half it is plain grid distance.
	check_eq(BoardGeometry.distance(BoardLocation.at(0, 0, 0), BoardLocation.at(0, 2, 3)), 5,
			"same-half distance is orthogonal steps")

	# Neighbours are exactly the cells one step away — including across the line, because
	# whether the line is a wall is a RULE and geometry does not hold rules.
	var mid := BoardLocation.at(0, 1, 1)
	check_eq(BoardGeometry.neighbours(mid).size(), 4, "an interior cell has four neighbours")
	var crossers: Array = BoardGeometry.neighbours(p_front)
	check(crossers.has(e_front), "a front-line cell neighbours the other half")


func _geometry_ordering() -> void:
	var origin := BoardLocation.at(0, 1, 1)
	var ordered: Array = BoardGeometry.cells_by_distance(origin)
	check_eq(ordered.size(), BoardData.ROWS * BoardData.COLS * 2, "the ordering covers the board")
	check(ordered[0] == origin, "the origin is nearest to itself")
	var last := -1
	var monotone := true
	for loc: BoardLocation in ordered:
		var d := BoardGeometry.distance(origin, loc)
		if d < last:
			monotone = false
		last = d
	check(monotone, "cells come back nearest-first")

	# Determinism: ties break in reading order, so the list is identical on every re-run.
	var again: Array = BoardGeometry.cells_by_distance(origin)
	var identical := true
	for i in ordered.size():
		if ordered[i] != again[i]:
			identical = false
	check(identical, "the ordering is reproducible")


# ── The manager ─────────────────────────────────────────────────────────────────────────

func _manager_two_questions() -> void:
	var m := LocationManager.new()
	var a := _probe("a")
	var loc := BoardLocation.at(0, 1, 2)

	check_eq(m.location_of(a), null, "an undocked thing has no location — an absence, not a sentinel")
	check_eq(m.at(loc, &"probe"), null, "an empty address answers nothing")
	check(not m.is_docked(a), "and it is not docked")

	check(m.dock(a, loc), "docking succeeds")
	check(m.location_of(a) == loc, "where is this thing")
	check_eq(m.at(loc, &"probe"), a, "what is at this location")

	m.move(a, BoardLocation.at(0, 2, 3))
	check_eq(m.at(loc, &"probe"), null, "moving vacates the old address")
	check(m.location_of(a) == BoardLocation.at(0, 2, 3), "and occupies the new one")
	check_eq(m.count(&"probe"), 1, "moving does not duplicate")

	m.undock(a)
	check_eq(m.location_of(a), null, "undocked things have no location again")
	check_eq(m.count(&"probe"), 0, "and the layer is empty")
	m.undock(a)
	check_eq(m.count(&"probe"), 0, "undocking twice is a no-op, not a complaint")

	# Docking at no location at all is refused — a location is minted or it does not exist.
	check(not m.dock(a, null), "refuses to dock at nothing")


func _manager_collisions() -> void:
	var m := LocationManager.new()
	var a := _probe("a")
	var b := _probe("b")
	var loc := BoardLocation.at(1, 0, 0)
	m.dock(a, loc)
	# A bug, not a situation: refuse and carry on, leaving the board untouched (§2.5).
	check(not m.dock(b, loc), "docking onto an occupied address is refused")
	check_eq(m.at(loc, &"probe"), a, "the sitting tenant is not evicted")
	check_eq(m.location_of(b), null, "and the intruder did not land anywhere")
	# Re-docking a thing where it already is is not a collision with itself.
	check(m.dock(a, loc), "re-docking in place is fine")


func _manager_layers() -> void:
	var m := LocationManager.new()
	var loc := BoardLocation.at(0, 0, 0)
	var piece := _probe("piece", &"pieces")
	var ground := _probe("ground", &"ground")
	check(m.dock(piece, loc), "a piece docks")
	check(m.dock(ground, loc), "and the ground under it docks at the same address")
	check_eq(m.at(loc, &"pieces"), piece, "the layers do not see each other")
	check_eq(m.at(loc, &"ground"), ground, "each layer answers for itself")
	check_eq(m.count(&"pieces"), 1, "one per layer per address")

	# Fixed address order, not insertion order.
	var m2 := LocationManager.new()
	m2.dock(_probe("late"), BoardLocation.at(1, 2, 3))
	m2.dock(_probe("early"), BoardLocation.at(0, 0, 0))
	var listed: Array = m2.docked(&"probe")
	check_eq((listed[0] as Probe).name, "early", "enumeration is in address order, not insertion order")


func _manager_copy() -> void:
	var m := LocationManager.new()
	var a := _probe("a")
	var b := _probe("b", &"ground")
	m.dock(a, BoardLocation.at(0, 1, 1))
	m.dock(b, BoardLocation.at(1, 2, 2))

	var a2 := _probe("a")
	var b2 := _probe("b", &"ground")
	var copy := m.copy({a: a2, b: b2})

	check(copy.location_of(a2) == BoardLocation.at(0, 1, 1), "the copy holds the copies' placement")
	check_eq(copy.location_of(a), null, "and knows nothing of the originals")
	check_eq(copy.at(BoardLocation.at(1, 2, 2), &"ground"), b2, "layers survive the copy")

	# The copy is a separate board: moving something on it must not move the original.
	copy.move(a2, BoardLocation.at(0, 0, 0))
	check(m.location_of(a) == BoardLocation.at(0, 1, 1), "a hypothetical never moves the real board")
