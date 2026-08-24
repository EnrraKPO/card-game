class_name StatMutationMutator
extends Mutator

# `stat_mutation` (Mutation §4): authored {"stat_mutation": {"stat": StringName,
# "delta": int}}. Concludes in a StatMutationRequest on the recipient.

var stat: StringName = &""
var delta: int = 0


func _init() -> void:
	kind = &"stat_mutation"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(
			StatMutationRequest.new(kind, plate.holder, recipient, stat, delta))
