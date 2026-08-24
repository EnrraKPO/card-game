class_name StatusMutator
extends Mutator

# `status` (Mutation §4): authored {"status": {"id": StringName, "stacks": int}}.
# Concludes in a StatusRequest on the recipient.

var id: StringName = &""
var stacks: int = 0


func _init() -> void:
	kind = &"status"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(StatusRequest.new(kind, plate.holder, recipient, id, stacks))
