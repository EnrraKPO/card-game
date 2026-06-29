class_name StatusEngine
extends RefCounted

# The operator for Statuses — the cross-cutting logic that keeps StatusData/StatusInstance (the
# state on a CardInstance) participating in the SAME effect pipeline as native card effects, with
# no per-status code:
#   • modifier_bonus    — folds a card's status MODIFIER effects into CardInstance.get_attribute
#                         at read-time (mirroring GameData.card_bonus), scaled by stack count.
#   • triggered_groups  — a card's active statuses (grouped) that have TRIGGERED/CUSTOM effects
#                         for an event, so EffectSystem.trigger fires them alongside the card's own.
#   • advance           — the per-round countdown: decrement ROUNDS statuses, drop expired.
# See StatusData, StatusInstance, EffectSystem.


# Summed delta of a card's status MODIFIER effects (card-scoped) for one attribute, each scaled
# by its status's stack count. Read-time, so expiry/removal needs no teardown.
static func modifier_bonus(inst: CardInstance, attr: String) -> int:
	var total := 0
	for si: StatusInstance in inst.statuses:
		for e: Effect in si.data.effects:
			if e.is_card_modifier() and e.card_attribute() == attr:
				total += e.amount_int() * si.stacks
	return total


# A card's active statuses that have TRIGGERED/CUSTOM effects matching an event, grouped per status
# so a stacked status's effects can scale together by its stack count.
# Returns Array of { "effects": Array[Effect], "stacks": int }.
static func triggered_groups(inst: CardInstance, event: Effect.Trigger) -> Array:
	var out: Array = []
	if inst == null:
		return out
	for si: StatusInstance in inst.statuses:
		var matched: Array = []
		for e: Effect in si.data.effects:
			if (e.kind == Effect.Kind.TRIGGERED or e.kind == Effect.Kind.CUSTOM) and e.trigger == event:
				matched.append(e)
		if not matched.is_empty():
			out.append({"effects": matched, "stacks": si.stacks})
	return out


# Advances a card's statuses for one round phase (ON_TURN_START / ON_TURN_END): each status whose
# decay_phase matches `event` counts down (its stack count for DECAY_STACKS, else its `remaining`
# timer) and is dropped if it hits zero. Run once per unit per phase, AFTER that phase's effects
# fire — so e.g. poison deals its damage from the current count, then the count drops.
static func advance(inst: CardInstance, event: Effect.Trigger) -> void:
	var kept: Array = []
	for si: StatusInstance in inst.statuses:
		if _decays_on(si, event):
			if si.data.decay == StatusData.DECAY_STACKS:
				si.stacks -= 1
			elif si.data.decay == StatusData.DECAY_DURATION and si.remaining > 0:
				si.remaining -= 1
		if not _is_expired(si):
			kept.append(si)
	inst.statuses = kept


static func _decays_on(si: StatusInstance, event: Effect.Trigger) -> bool:
	if si.data.decay == StatusData.DECAY_NONE:
		return false
	match si.data.decay_phase:
		StatusData.PHASE_TURN_START: return event == Effect.Trigger.ON_TURN_START
		StatusData.PHASE_ACTIVATE:   return event == Effect.Trigger.ON_ACTIVATE
		_:                           return event == Effect.Trigger.ON_TURN_END


static func _is_expired(si: StatusInstance) -> bool:
	if si.data.decay == StatusData.DECAY_STACKS:
		return si.stacks <= 0
	if si.data.decay == StatusData.DECAY_DURATION:
		return si.remaining == 0
	return false
