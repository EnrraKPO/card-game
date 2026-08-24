class_name RefillMutator
extends Mutator

# `refill` (Combat Frame §4): machinery only — the refill rule's ask. Raises the
# recipient side's `mana` to its `mana_capacity` — a raise, never a drain: mana already
# above capacity stays (B32).


func _init() -> void:
	kind = &"refill"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var missing: int = roundi(recipient.get_stat(&"mana_capacity") - recipient.get_stat(&"mana"))
	if missing <= 0:
		return []
	return MutationEngine.submit(
			StatMutationRequest.new(kind, plate.holder, recipient, &"mana", missing))
