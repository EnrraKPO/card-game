class_name DamageMutator
extends Mutator

# `damage` (Mutation §4): authored {"damage": {"amount": int}}. Concludes in a
# DamageRequest on the recipient.

var amount: int = 0


func _init() -> void:
	kind = &"damage"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(DamageRequest.new(kind, plate.holder, recipient, amount))
