class_name IsSideCondition
extends EntityCondition

# `is_side` (roster growth, B36): no members; a type check. Demanded by the Hourglass
# relic — its draw's recipient is the holder's own Side, and the resolver narrows to it
# by allegiance plus this kind.


func _answer(_plate: Plate, subject: GameEntity) -> bool:
	return subject is Side
