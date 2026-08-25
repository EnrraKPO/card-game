class_name ShieldRecoveryMutator
extends Mutator

# `shield_recovery` (Combat Frame §4, A13): machinery only — the shield recovery rule's
# ask. Raises the recipient unit's `shield` to its authored value — a raise, never a
# drain: shield standing above the authored value stays. The authored value is the
# registered envelope's (ContentLibrary); a unit authored without shield recovers to
# nothing. A recipient already at or above it needs no ask.


func _init() -> void:
	kind = &"shield_recovery"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var authored: float = ContentLibrary.authored_stat(recipient.id, &"shield")
	var missing: int = roundi(authored - recipient.get_stat(&"shield"))
	if missing <= 0:
		return []
	return MutationEngine.submit(
			StatMutationRequest.new(kind, plate.holder, recipient, &"shield", missing))
