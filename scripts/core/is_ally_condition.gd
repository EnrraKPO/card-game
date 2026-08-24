class_name IsAllyCondition
extends EntityCondition

# `is_ally` (A8): no members. The subject's allegiance (A4) compared to the holder's —
# true when both are stated and the same. An entity of no side (the Game) is nobody's
# ally.


func _answer(plate: Plate, subject: GameEntity) -> bool:
	var mine: Side = plate.holder.allegiance
	return mine != null and subject.allegiance == mine
