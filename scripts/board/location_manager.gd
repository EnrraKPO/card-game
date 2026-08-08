class_name LocationManager
extends RefCounted

# THE sole container of board coordinates (LOCATION_MANAGER_DESIGN.md §2.1). Anything that
# sits on the board is a DOCKABLE; a dockable never knows where it is and must ask. A unit is
# not the authority on its own position — the board moves it.
#
# IT ANSWERS "WHAT IS HERE", NEVER "WHAT IS A VALID TARGET" (§2.9). Emptiness is an answer,
# not a miss. It cannot know what "valid" means; the caller does.
#
# ITS IGNORANCE IS TOTAL AND UNIFORM (§2.3). It does not know what a unit is, and it equally
# does not know what a slot is. It never looks inside a dockable. The ONE exception is the
# LAYER, and that stays honest only while the layer is an opaque tag the dockable declares —
# this file must never contain a list of known layer names, nor branch on which layer
# something is on. If it ever does, the ignorance has leaked.
#
# COLLISIONS ARE UNREPRESENTABLE (§2.5). One dockable per location per layer. Docking onto an
# occupied address is a BUG, not a situation: assert, refuse, carry on.
#
# IT LIVES INSIDE THE COMBAT WORLD, NOT AS A GLOBAL (§4.2). Simulations copy the whole world
# to try out plans; a globally reachable manager would silently share placement between a
# hypothetical and the real board — the worst place for a bug to hide.
#
# DOCKABLES HOLD NO BACK-REFERENCE HERE (§4.2). A copied unit pointing at the ORIGINAL
# world's manager would report positions from the wrong board, silently, and only inside
# simulations. Callers reach the manager through the world they are already holding.

# layer tag -> { Vector3i address -> dockable }
var _at: Dictionary = {}
# layer tag -> { dockable -> BoardLocation }
var _of: Dictionary = {}


# The layer a dockable declares itself to be on. The manager files by this tag and compares
# tags; it never interprets one. A dockable that cannot answer is an authoring bug — loud,
# because a silent answer here becomes a piece that occupies nothing.
static func layer_of(dockable: Object) -> StringName:
	if dockable == null:
		return &""
	if not dockable.has_method("dock_layer"):
		push_error("LocationManager: %s is not a dockable (no dock_layer)" % dockable)
		return &""
	var tag: StringName = dockable.call("dock_layer")
	return tag


# ── Docking ─────────────────────────────────────────────────────────────────────────────

# Put a dockable at a location. False = refused, and a refusal is always a bug that has
# already been reported. A dockable already docked elsewhere is MOVED (see move) rather than
# duplicated — two entries for one thing is the two-authorities state this exists to end.
func dock(dockable: Object, loc: BoardLocation) -> bool:
	if dockable == null:
		return false
	if loc == null:
		push_error("LocationManager: refusing to dock %s at no location" % dockable)
		return false
	var layer := layer_of(dockable)
	if layer == &"":
		return false
	var by_address: Dictionary = _layer_at(layer)
	var occupant: Object = by_address.get(loc.key())
	if occupant != null and occupant != dockable:
		push_error("LocationManager: %s is already docked at %s on layer '%s' — refusing %s"
				% [occupant, loc, layer, dockable])
		return false
	undock(dockable)
	by_address[loc.key()] = dockable
	_layer_of(layer)[dockable] = loc
	return true


# Take a dockable off the board. Undocking something that was never docked is a no-op, not a
# complaint: "not on the board" is a state, and removal paths run more than once.
func undock(dockable: Object) -> void:
	if dockable == null:
		return
	var layer := layer_of(dockable)
	if layer == &"":
		return
	var by_dockable: Dictionary = _layer_of(layer)
	var was: BoardLocation = by_dockable.get(dockable)
	if was == null:
		return
	by_dockable.erase(dockable)
	_layer_at(layer).erase(was.key())


# Move a docked thing to another cell. Identical to dock() — spelled separately because the
# call sites read as movement and because it is the operation the collision rule guards.
func move(dockable: Object, loc: BoardLocation) -> bool:
	return dock(dockable, loc)


# ── The two questions ───────────────────────────────────────────────────────────────────

# WHERE IS THIS THING. Null = it is not on the board — an honest absence, not a sentinel
# coordinate (a relic has no location; so does a card in hand, and a unit that just died).
func location_of(dockable: Object) -> BoardLocation:
	if dockable == null:
		return null
	var layer := layer_of(dockable)
	if layer == &"":
		return null
	return _layer_of(layer).get(dockable)


# WHAT IS AT THIS LOCATION, on this layer. Null = nothing is — an answer, not a miss.
func at(loc: BoardLocation, layer: StringName) -> Object:
	if loc == null:
		return null
	return _layer_at(layer).get(loc.key())


func is_docked(dockable: Object) -> bool:
	return location_of(dockable) != null


# Everything docked on one layer, in fixed address order (side, row, col). Fixed because
# simulations re-run and must reproduce results exactly (§4.2) — a Dictionary promises no
# order, so the order is sorted into existence rather than trusted.
func docked(layer: StringName) -> Array:
	var by_address: Dictionary = _layer_at(layer)
	var keys: Array = by_address.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	var out: Array = []
	for k: Vector3i in keys:
		out.append(by_address[k])
	return out


func count(layer: StringName) -> int:
	return _layer_at(layer).size()


# ── Copying ─────────────────────────────────────────────────────────────────────────────

# The placement half of a world snapshot. Every dockable resolves through the SAME identity
# remap the rest of the copy uses, so the copied board holds copies and never reaches back
# into the live one. A dockable missing from the remap is a copy pass that forgot something:
# loud, because silently dropping a piece changes the board a simulation reasons about.
func copy(remap: Dictionary) -> LocationManager:
	var out := LocationManager.new()
	for layer: StringName in _of:
		var by_dockable: Dictionary = _of[layer]
		for dockable: Object in by_dockable:
			var twin: Object = remap.get(dockable)
			if twin == null:
				push_error("LocationManager.copy: no copy registered for %s — dropping it" % dockable)
				continue
			out.dock(twin, by_dockable[dockable])
	return out


# ── Internals ───────────────────────────────────────────────────────────────────────────

func _layer_at(layer: StringName) -> Dictionary:
	if not _at.has(layer):
		_at[layer] = {}
	return _at[layer]


func _layer_of(layer: StringName) -> Dictionary:
	if not _of.has(layer):
		_of[layer] = {}
	return _of[layer]
