class_name BuryMutator
extends Mutator

# `bury` (Kind Rosters §3): machinery only — never authored. Its BuryRequest targets the
# recipient; BuryProcedure places the target in its side's graveyard (Core §6).
# Unit burial rides the AutoResolver — the recipient is died's native target, the dead
# unit; the spell burial's holder-electing resolver hands the holder.


func _init() -> void:
	kind = &"bury"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	return MutationEngine.submit(BuryRequest.new(kind, plate.holder, recipient))
