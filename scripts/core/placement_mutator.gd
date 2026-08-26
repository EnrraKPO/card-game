class_name PlacementMutator
extends Mutator

# `placement` (Mutation §4): machinery only — never authored. A baked-in substantive
# mutator of the unit's play (Core §6, A18), and the Move ability's carrier (Core §7;
# A3). Recipient the elected slot; act: container move of the holder into the
# recipient's `slotted_unit` — the container name fixed in the kind.


func _init() -> void:
	kind = &"placement"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(ContainerMoveRequest.new(
			kind, plate.holder, plate.holder, recipient, &"slotted_unit"))
