class_name RampMutator
extends Mutator

# `ramp` (Combat Frame §4): machinery only — the ramp rule's ask. Raises the recipient
# side's `mana_capacity` by the ramp amount, read from the Game's `mana_ramp` stat at
# issuance — the number stays a Game stat, mutable through the road. Capacity is
# uncapped.


func _init() -> void:
	kind = &"ramp"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var amount: int = roundi(plate.world().game.get_stat(&"mana_ramp"))
	if amount == 0:
		return []
	return MutationEngine.submit(
			StatMutationRequest.new(kind, plate.holder, recipient, &"mana_capacity", amount))
