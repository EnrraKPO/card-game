class_name StatusEngine
extends RefCounted

# The operator for Statuses — the cross-cutting logic that keeps StatusData/StatusInstance (the
# state on a CardInstance) participating in the SAME effect pipeline as native card effects, with
# no per-status code:
#   • triggered_groups  — a card's active statuses (grouped) that have TRIGGERED/CUSTOM effects
#                         for an event, so EffectSystem.trigger fires them alongside the card's own.
#   • advance           — the per-round countdown: decrement ROUNDS statuses, drop expired.
# (Status-held STANDING effects fold into get_attribute through LiveEffects — the one
# evaluator shared with every other container; nothing status-specific remains on that path.)
# See StatusData, StatusInstance, EffectSystem, LiveEffects.


# A card's active statuses that have TRIGGERED/CUSTOM effects matching an event, grouped per status
# (so a stacked status's effects scale together, and the dispatcher can cue each status's pip as the
# container before its effects). Returns Array of { "status_id": String, "effects": Array[Effect],
# "stacks": int }.
static func triggered_groups(inst: CardInstance, event_id: StringName) -> Array:
	var out: Array = []
	if inst == null:
		return out
	for si: StatusInstance in inst.statuses:
		var matched: Array = []
		for e: Effect in si.data.effects:
			# Cheap event-id prefilter; the full activation gate (participant conditions)
			# runs in EffectSystem.trigger_grouped via the same resolver.
			if (e.kind == Effect.Kind.TRIGGERED or e.kind == Effect.Kind.CUSTOM) \
					and e.trigger_resolver().listens(event_id):
				matched.append(e)
		if not matched.is_empty():
			out.append({"status_id": si.data.id, "effects": matched, "stacks": si.stacks})
	return out


# Advances a card's statuses for one round phase (ON_TURN_START / ON_TURN_END): each status whose
# decay_phase matches `event` counts down (its stack count for DECAY_STACKS, else its `remaining`
# timer) and is dropped if it hits zero. Run once per unit per phase, AFTER that phase's effects
# fire — so e.g. poison deals its damage from the current count, then the count drops.
static func advance(inst: CardInstance, event_id: StringName) -> void:
	var kept: Array = []
	for si: StatusInstance in inst.statuses:
		if _decays_on(si, event_id):
			if si.data.decay == StatusData.DECAY_STACKS:
				si.stacks -= 1
			elif si.data.decay == StatusData.DECAY_DURATION and si.remaining > 0:
				si.remaining -= 1
		if not is_expired(si):
			kept.append(si)
	inst.statuses = kept


static func _decays_on(si: StatusInstance, event_id: StringName) -> bool:
	# NONE never decays; INTERCEPT decays only via consume_interception (not phase-driven).
	if si.data.decay == StatusData.DECAY_NONE or si.data.decay == StatusData.DECAY_INTERCEPT:
		return false
	match si.data.decay_phase:
		StatusData.PHASE_TURN_START: return event_id == &"turn_start"
		StatusData.PHASE_ACTIVATE:   return event_id == &"activate"
		StatusData.PHASE_ATTACK:     return event_id == &"attack"
		_:                           return event_id == &"turn_end"


# Whether a status instance's decay state says it is over. Public: StatusInstance.exists()
# (the tracker existence probe) pull-checks this on every read — removal is hygiene only.
static func is_expired(si: StatusInstance) -> bool:
	if si.data.decay == StatusData.DECAY_STACKS or si.data.decay == StatusData.DECAY_INTERCEPT:
		return si.stacks <= 0
	if si.data.decay == StatusData.DECAY_DURATION:
		return si.remaining == 0
	return false


# Spends one charge of an intercept-decay status, called by Resolver._try_intercept after one
# of the status's INTERCEPTOR effects actually rewrote a mutation (a rewrite that changed
# nothing never reaches here — a Barrier ignores a whiff). Phase-decay statuses (Blind) are
# untouched: they spend on their own phase via advance() instead.
static func consume_interception(holder: CardInstance, status_id: String) -> void:
	var si := holder.find_status(status_id)
	if si == null or si.data.decay != StatusData.DECAY_INTERCEPT:
		return
	si.stacks -= 1
	if si.stacks <= 0:
		holder.remove_status(status_id)
