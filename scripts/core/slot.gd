class_name Slot
extends GameEntity

# A board Slot (Core System Design §1, §3): its coordinate — row and column within its
# half — is set at construction and never changes. It declares the `slotted_unit`
# container; a unit is fielded in a slot when it is a member of that container (§2).
#
# A slot's side is the side owning the `board` container that houses it (§1) — the
# BoardManager births every slot housed on its side, so the allegiance birth fact (Core §1)
# and that read name the same Side, always.

var _row: int = -1
var _col: int = -1

var row: int:
	get: return _row

var col: int:
	get: return _col


func _init(p_row: int, p_col: int, p_allegiance: Side) -> void:
	super._init(p_allegiance)
	_row = p_row
	_col = p_col


func _declared_containers() -> Array[StringName]:
	var out: Array[StringName] = super._declared_containers()
	out.append(&"slotted_unit")
	return out
