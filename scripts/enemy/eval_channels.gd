class_name EvalChannels
extends RefCounted

# The capture-time fold of AUTHORED eval annotations into the enemy engine's three
# channels (STATUS_EVAL_BRIEF.md): threat ("I'm dangerous" — damage out per round),
# exposure ("I'm in danger" — damage in per round), value (everything neither — value
# units). Two authoring levels feed one sum:
#   · EFFECT level (Effect.eval_mods) — flat, applied once per carrier. Card effects,
#     status-borne effects and innates all speak it; none of them knows what a stack is.
#   · STATUS level (StatusData.eval_mods) — per-stack adds, folded × stacks (stacks ARE
#     the quantity — StatusEngine.is_expired).
# Muls fold multiplicatively and are applied by the CONSUMPTION sites after all adds,
# around the unit's native base — (base + adds) × muls (BoardScoring).
#
# This fold runs at BoardState capture only (UnitState.from_instance / the ground map) —
# the game rules never read these numbers, and the numbers are never derived from what an
# effect does (that would be the discarded channel-taxonomy appraiser). Everything
# unannotated contributes nothing: the engine degrades to exactly its channel-blind self.


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

	# The flat effect-level contribution: adds sum, muls multiply.
	func fold_effect(e: Effect) -> void:
		if e.eval_mods.is_empty():
			return
		threat_add += e.eval_add("threat")
		threat_mul *= e.eval_mul("threat")
		exposure_add += e.eval_add("exposure")
		exposure_mul *= e.eval_mul("exposure")
		value_add += e.eval_add("value")
		value_mul *= e.eval_mul("value")

	# The per-stack status-level contribution (adds only — StatusData refuses muls).
	func fold_status(sdata: StatusData, stacks: int) -> void:
		if sdata.eval_mods.is_empty():
			return
		threat_add += sdata.eval_add("threat") * float(stacks)
		exposure_add += sdata.eval_add("exposure") * float(stacks)
		value_add += sdata.eval_add("value") * float(stacks)


# The whole unit fold: the card's own effects, the innate rules it carries, and its
# statuses (each status's per-stack adds × stacks, plus its effects' flat annotations).
# Returns null for the neutral fold — the read model stores nothing for the common
# (unannotated) case, and the scoring helpers treat null as neutral.
static func unit_mods(inst: CardInstance) -> Mods:
	var m := Mods.new()
	for e: Effect in inst.data.effects:
		m.fold_effect(e)
	for e: Effect in InnateEffects.all():
		if _innate_carried(e, inst):
			m.fold_effect(e)
	_fold_statuses(m, inst)
	return null if m.is_neutral() else m


# The ground fold: a slot is pure statuses (BoardSlot stores nothing else).
static func slot_mods(slot: BoardSlot) -> Mods:
	var m := Mods.new()
	_fold_statuses(m, slot)
	return null if m.is_neutral() else m


static func _fold_statuses(m: Mods, carrier: StatusCarrier) -> void:
	for si: StatusInstance in carrier.statuses:
		m.fold_status(si.data, si.stacks)
		for e: Effect in si.data.effects:
			m.fold_effect(e)


# Whether an INNATE rule's annotation belongs to this unit. Innates are global rules gated
# by their own trigger conditions, so attribution means asking the holder-side gate
# statically: a dual-event rule about the holder's own action (origin_of self) carries its
# annotation on every unit its origin conditions admit right now. Other trigger shapes
# cannot be attributed statically in this build — their annotations fold onto no one
# (documented v1 limit; extend per shape when a rule forces it).
static func _innate_carried(e: Effect, inst: CardInstance) -> bool:
	if e.eval_mods.is_empty():
		return false
	var tr := e.trigger_resolver()
	if tr is TriggerResolver.Dual:
		var dual := tr as TriggerResolver.Dual
		if not dual.origin_of_holder:
			return false
		return TriggerResolver.conditions_pass(dual.origin_conditions, inst, inst.owner)
	return false
