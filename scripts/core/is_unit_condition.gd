class_name IsUnitCondition
extends EntityCondition

# `is_unit` (Kind Rosters §1): no members; a type check.


func _answer(_plate: Plate, subject: GameEntity) -> bool:
	return subject is Unit
