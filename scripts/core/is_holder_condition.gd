class_name IsHolderCondition
extends EntityCondition

# `is_holder` (Kind Rosters §1): no members. True when the subject is the plate's holder. Under
# route `source` it is the discriminating condition of every play and every ability — the
# source fetch is the route's work.


func _answer(plate: Plate, subject: GameEntity) -> bool:
	return subject == plate.holder
