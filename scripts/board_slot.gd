class_name BoardSlot
extends StatusCarrier

# One cell of the GROUND layer: a filing cabinet with an address. The board is a stack of
# layers over one shared coordinate space — ground (slots, permanent) under pieces (units,
# transient) — and co-location is INCIDENTAL: a unit is "on top of" its slot, never inside
# it. Occupancy is therefore NOT stored here (the unit grids stay the single authority —
# ask the world); a slot stores only what it is the authority on: its own address and its
# filed statuses. See SLOT_LAYER_DESIGN.md.
#
# `side` is spatial addressing (which half's coordinate space row/col live in), NOT the
# allegiance of anything the slot does — allegiance is answered per-dispatch through the
# context's owner_anchor (the ground inherits the half it sits on, until a mechanic needs
# otherwise; see CombatCascade's ground pass).

var side: int = -1   # 0 = player half, 1 = enemy half
var row: int = -1
var col: int = -1


static func make(p_side: int, p_row: int, p_col: int) -> BoardSlot:
	var s := BoardSlot.new()
	s.side = p_side
	s.row = p_row
	s.col = p_col
	return s
