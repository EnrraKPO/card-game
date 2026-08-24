class_name PlacementMutator
extends Mutator

# `placement` (Mutation §4): machinery only — never authored; serves placement and the
# Move ability (Core §6, §7; A3). Recipient the elected slot; act: container move of the
# holder into the recipient's `slotted_unit` — the container name fixed in the kind. The
# insert produces `fielded` where the origin was off-board (Core §2).


func _init() -> void:
	kind = &"placement"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(ContainerMoveRequest.new(
			kind, plate.holder, plate.holder, recipient, &"slotted_unit"))
