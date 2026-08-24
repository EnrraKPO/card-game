class_name BurialMutator
extends Mutator

# `burial` (Mutation §4): machinery only — never authored. A container move of the
# HOLDER to its side's graveyard (Core §6); the destination's container name is fixed in
# the kind. The recipient plays no part: the burial effect's default resolver targets
# the Game, and the buried party is the effect's holder.


func _init() -> void:
	kind = &"burial"


func _issue(plate: Plate, _recipient: GameEntity) -> Array[Event]:
	var side: Side = plate.holder.allegiance
	if side == null:
		push_error("BurialMutator: the holder belongs to no side — no graveyard to reach")
		return []
	return MutationEngine.submit(
			ContainerMoveRequest.new(kind, plate.holder, plate.holder, side, &"graveyard"))
