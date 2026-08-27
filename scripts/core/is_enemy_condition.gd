class_name IsEnemyCondition
extends EntityCondition

# `is_enemy` (Kind Rosters §1): no members. The subject's allegiance (A4) compared to the holder's —
# true when both are stated and different. An entity of no side (the Game) is nobody's
# enemy.


func _answer(plate: Plate, subject: GameEntity) -> bool:
	var mine: Side = plate.holder.allegiance
	var theirs: Side = subject.allegiance
	return mine != null and theirs != null and theirs != mine
