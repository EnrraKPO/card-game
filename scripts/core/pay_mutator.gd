class_name PayMutator
extends Mutator

# `pay` (Kind Rosters §3): machinery only — never authored; unique. Runs once per delivery,
# before the walk; it appoints its own target from the plate: the holder's side, whose
# mana pays (Core §5, §1). The produced event's name derives from the occasion —
# `play` engages as `play_engaged`, `use_ability` as `ability_used` with the asked
# ability's name carried forward (Core §7).
#
# The amounts: a play's mana is the holder's cost stat, read at issuance (discounts are
# ordinary stat mutations); an ability's cost is authored on the ability and fixed here
# at its expansion (B23).

# -1 = read the holder's cost stat at issuance; a fixed amount otherwise.
var mana: int = -1
var tap: int = 0


func _init(p_mana: int = -1, p_tap: int = 0) -> void:
	kind = &"pay"
	mana = p_mana
	tap = p_tap


func is_unique() -> bool:
	return true


func _issue(plate: Plate, _recipient: GameEntity) -> Array[Event]:
	var side: Side = plate.holder.allegiance
	if side == null:
		push_error("PayMutator: the holder belongs to no side — no mana to pay with")
		return []
	var owed: int = mana if mana >= 0 else roundi(plate.holder.get_stat(&"cost"))
	var engaged_name: StringName
	var ability: StringName = &""
	match plate.occasion.name:
		&"play":
			engaged_name = &"play_engaged"
		&"use_ability":
			engaged_name = &"ability_used"
			for component: EventData in plate.occasion.components_of(NameEventData):
				var named := component as NameEventData
				if named.role == &"ability":
					ability = named.name
		_:
			push_error("PayMutator: no engaged name derives from occasion '%s'"
					% plate.occasion.name)
			return []
	return MutationEngine.submit(PayCostRequest.new(
			kind, plate.holder, side, owed, tap, engaged_name, ability))
