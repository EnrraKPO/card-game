class_name StrikeMutator
extends Mutator

# `strike` (Mutation §4): no parameters. Asks that the recipient be struck — the striker
# is the holder. Concludes in a StrikeRequest.


func _init() -> void:
	kind = &"strike"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(StrikeRequest.new(kind, plate.holder, recipient))
