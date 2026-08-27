class_name PlacementMutator
extends Mutator

# `placement` (Mutation §4): machinery only — never authored. A baked-in substantive
# mutator of the unit's play (Core §6): the play's resolver elects the slot — the
# move op's destination target — and the mutator introduces the holder as cargo into
# the MoveRequest (Core §2), the container name fixed: `slotted_unit`.


func _init() -> void:
	kind = &"placement"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(MoveRequest.new(
			kind, plate.holder, recipient, plate.holder, &"slotted_unit"))
