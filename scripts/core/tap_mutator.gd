class_name TapMutator
extends Mutator

# `tap` (Combat Frame §6): machinery only, unique. Recipient null — it appoints its
# holder and concludes in a StatMutationRequest setting `tapped`: the main action's
# spend, one tap.


func _init() -> void:
	kind = &"tap"


func is_unique() -> bool:
	return true


func _issue(plate: Plate, _recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(
			StatMutationRequest.new(kind, plate.holder, plate.holder, &"tapped", 1))
