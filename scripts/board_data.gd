class_name BoardData
extends RefCounted

const COLS := 4
const ROWS := 3

# Board slot layout, shared by the board builder and combat's responsive resizer.
const SLOT_GAP := 14                  # separation between slots within a board half
const SLOT_ASPECT := 216.0 / 165.0    # card height / width (matches SlotUI's authored size)
