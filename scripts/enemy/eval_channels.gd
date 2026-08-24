class_name EvalChannels
extends RefCounted

# The capture-time fold of AUTHORED eval annotations into the enemy engine's three
# channels (STATUS_EVAL_BRIEF.md): threat ("I'm dangerous" — damage out per round),
# exposure ("I'm in danger" — damage in per round), value (everything neither — value
# units). Muls fold multiplicatively and are applied by the CONSUMPTION sites after all
# adds, around the unit's native base — (base + adds) × muls (BoardScoring).
#
# This fold runs at BoardState capture only (UnitState.from_instance / the ground map) —
# the game rules never read these numbers. Everything unannotated contributes nothing:
# the engine degrades to exactly its channel-blind self.
#
# STATUS level only, today: per-stack adds authored on the status (StatusData.eval_mods),
# folded × stacks (stacks ARE the quantity — StatusEngine.is_expired; muls are refused at
# this level). The EFFECT-level half — flat annotations on the carried effects, the
# is_spent battlecry gate, innate attribution — died with the effect layer (2026-08-11)
# and returns as pricing on the rebuilt structures. Its preserved rules: spent effects
# (a trigger gated to the holder's OWN play event) are never priced — by pricing time the
# play moment is history and its consequences are IN the state being scored; an innate
# rule's annotation folds onto exactly the units its origin conditions admit.


# One carrier's folded (add, mul) pair per channel. Plain data; treated as IMMUTABLE once
# the fold returns it, so copies of the read model may share instances.
class Mods:
	extends RefCounted

	var threat_add: float = 0.0
	var threat_mul: float = 1.0
	var exposure_add: float = 0.0
	var exposure_mul: float = 1.0
	var value_add: float = 0.0
	var value_mul: float = 1.0

	func is_neutral() -> bool:
		return threat_add == 0.0 and threat_mul == 1.0 \
				and exposure_add == 0.0 and exposure_mul == 1.0 \
				and value_add == 0.0 and value_mul == 1.0

	# The per-stack status-level contribution (adds only — StatusData refuses muls).
	func fold_status(sdata: StatusData, stacks: int) -> void:
		if sdata.eval_mods.is_empty():
			return
		threat_add += sdata.eval_add("threat") * float(stacks)
		exposure_add += sdata.eval_add("exposure") * float(stacks)
		value_add += sdata.eval_add("value") * float(stacks)


# The whole unit fold: the unit's statuses' per-stack adds × stacks. Returns null for the
# neutral fold — the read model stores nothing for the common (unannotated) case, and the
# scoring helpers treat null as neutral.
static func unit_mods(inst: CardInstance) -> Mods:
	var m := Mods.new()
	_fold_statuses(m, inst)
	return null if m.is_neutral() else m


# The ground fold: a slot is pure statuses (BoardSlot stores nothing else).
static func slot_mods(slot: BoardSlot) -> Mods:
	var m := Mods.new()
	_fold_statuses(m, slot)
	return null if m.is_neutral() else m


static func _fold_statuses(m: Mods, carrier: LegacyGameEntity) -> void:
	for si: StatusInstance in carrier.statuses:
		m.fold_status(si.data, si.stacks)
