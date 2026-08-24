class_name BakedConditions
extends RefCounted

# The machinery's baked conditions (Core §5, §7; Combat Frame §6). Machinery, not
# authored vocabulary: none of these appear in the parse tables; the type machinery and
# the ability expansion construct them in code. Housed together because they are one
# family of small fixed reads — each still a Condition like any other (B28).


# One definition of "can this holder pay": the play effect's baked affordability, the
# use effect's, and the payability query all ask here. mana −1 = the holder's cost stat
# (the play's form); a tap price is affordable while the holder is untapped.
static func affordable(holder: GameEntity, mana: int, tap: int) -> bool:
	var side: Side = holder.allegiance
	if side == null:
		return false
	var owed: int = mana if mana >= 0 else roundi(holder.get_stat(&"cost"))
	if side.get_stat(&"mana") < float(owed):
		return false
	if tap > 0 and holder.get_stat(&"tapped") > 0.0:
		return false
	return true


# Affordability (Core §5, §7): the cost within open mana. Serves on route `holder`.
class Affordability extends EntityCondition:
	var mana: int = -1
	var tap: int = 0

	func _init(p_mana: int, p_tap: int) -> void:
		mana = p_mana
		tap = p_tap

	func _answer(_plate: Plate, subject: GameEntity) -> bool:
		return BakedConditions.affordable(subject, mana, tap)


# Holder-in-hand (Core §5): the play asks a card that is in a hand.
class InHand extends EntityCondition:
	func _answer(_plate: Plate, subject: GameEntity) -> bool:
		return subject.housing != null and subject.housing.name == &"hand"


# Untapped (Combat Frame §6): the main action's baked condition.
class Untapped extends EntityCondition:
	func _answer(_plate: Plate, subject: GameEntity) -> bool:
		return subject.get_stat(&"tapped") == 0.0


# A Slot (the play's and Move's pick narrows to slots).
class IsSlot extends EntityCondition:
	func _answer(_plate: Plate, subject: GameEntity) -> bool:
		return subject is Slot


# A vacant slot: its `slotted_unit` container houses nothing (B28).
class SlotVacant extends EntityCondition:
	func _answer(_plate: Plate, subject: GameEntity) -> bool:
		return subject is Slot and (subject as Slot).get_container(&"slotted_unit").members.is_empty()


# Fielded: housed in a slot's `slotted_unit` (Core §2) — the untap rule's narrowing.
class Fielded extends EntityCondition:
	func _answer(_plate: Plate, subject: GameEntity) -> bool:
		return subject.housing != null and subject.housing.name == &"slotted_unit"


# A Side — the base rules that reach each side narrow by this (Combat Frame §4).
class IsSide extends EntityCondition:
	func _answer(_plate: Plate, subject: GameEntity) -> bool:
		return subject is Side
