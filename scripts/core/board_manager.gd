class_name BoardManager
extends RefCounted

# The BoardManager (Core System Design §3): one instance, embedded in the world. Two
# duties, exactly:
#
#   · Birth — at world construction, mint both halves' slots, stamp their coordinates,
#     house them through the membership primitives, and file each in the index. One act.
#   · Fetch — address → slot: a direct map built once at birth over immutable facts, one
#     lookup. And "slots at these addresses" for a list.
#
# Addresses are BoardGeometry's Vector3i(side, row, col); the half index matches the
# sides container's order. Slot references in the index are strong beside the ownership
# tree's own — slots never leave their board container, and the index dies with the
# manager, with the world.

var _index: Dictionary[Vector3i, Slot] = {}


# The one act of birth. Each side's half is ROWS × COLS slots, housed in that side's
# `board` container in reading order — the per-side slot order the gather's comparator
# keys on (Mutation §12).
func birth(world: World, sides: Array[Side]) -> void:
	for side_index: int in sides.size():
		var side: Side = sides[side_index]
		var board: EntityContainer = side.get_container(&"board")
		for row: int in BoardGeometry.ROWS:
			for col: int in BoardGeometry.COLS:
				var slot := Slot.new(row, col, side)
				WriteAuthority.mint(world, slot)
				WriteAuthority.insert(board, slot)
				_index[Vector3i(side_index, row, col)] = slot


# Address → slot. Null = that is not a cell — an answer for a shape running off the
# board's edge, not an error.
func slot_at(address: Vector3i) -> Slot:
	return _index.get(address)


# Slots at these addresses, in the given order; addresses off the board yield nothing.
func slots_at(addresses: Array[Vector3i]) -> Array[Slot]:
	var out: Array[Slot] = []
	for address: Vector3i in addresses:
		var slot: Slot = _index.get(address)
		if slot != null:
			out.append(slot)
	return out
