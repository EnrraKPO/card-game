class_name HousesMeCondition
extends EntityCondition

# `houses_me` (Kind Rosters §1): no members. True when the subject owns the container housing the
# holder — a status's read of the unit carrying it.


func _answer(plate: Plate, subject: GameEntity) -> bool:
	var housing: EntityContainer = plate.holder.housing
	return housing != null and housing.owner == subject
