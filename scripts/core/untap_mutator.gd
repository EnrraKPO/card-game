class_name UntapMutator
extends Mutator

# `untap` (Combat Frame §4): machinery only — the untap rule's ask. Clears the
# recipient's `tapped`: reads the spent taps and asks the delta that zeroes them —
# unbounded internals, one StatMutationRequest. An untapped recipient needs no ask.


func _init() -> void:
	kind = &"untap"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var spent: int = roundi(recipient.get_stat(&"tapped"))
	if spent == 0:
		return []
	return MutationEngine.submit(
			StatMutationRequest.new(kind, plate.holder, recipient, &"tapped", -spent))
