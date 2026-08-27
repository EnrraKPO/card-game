class_name MoveUnitMutator
extends Mutator

# `move_unit` (Kind Rosters §3): machinery only — never authored; the Move ability's
# carrier (A9). The same operation as the placement, each its own stake
# (Core §2): the use effect's resolver elects the slot — the destination target —
# and the mutator introduces the holder as cargo, the container name fixed:
# `slotted_unit`.


func _init() -> void:
	kind = &"move_unit"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(MoveRequest.new(
			kind, plate.holder, recipient, plate.holder, &"slotted_unit"))
