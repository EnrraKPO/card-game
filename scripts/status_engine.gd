class_name StatusEngine
extends RefCounted

# The operator for Statuses — ALL the rules of status behavior, so carriers (units, later
# slots — see StatusCarrier) hold their list and have zero say:
#   • apply             — the one application writer: stacking policy, clamping, refresh.
#   • triggered_groups  — a carrier's active statuses (grouped) that have TRIGGERED/CUSTOM effects
#                         for an event, so EffectSystem.trigger fires them alongside the card's own.
#   • advance           — the per-round countdown: decrement ROUNDS statuses, drop expired.
# (Status-held STANDING effects fold into get_attribute through LiveEffects — the one
# evaluator shared with every other container; nothing status-specific remains on that path.)
# See StatusData, StatusInstance, StatusCarrier, EffectSystem, LiveEffects.


# Applies a status (by id) to a carrier, combining with an existing one of the same id per the
# status's stacking rule. `duration` defaults to the status's own (pass to override); a status
# whose kind is "combat" always lasts the whole fight regardless. See StatusData.
static func apply(carrier: StatusCarrier, status_id: String, duration: int = Effect.STATUS_DURATION_DEFAULT, stacks: int = 1, src: CardInstance = null) -> void:
	if carrier == null:
		return
	var sdata := StatusData.get_status(status_id)
	if sdata == null:
		return
	# Status storage write — a status may carry composition grants (see LiveEffects). The
	# Resolver-routed path invalidates in submit too; hooking the storage level as well keeps
	# direct callers (tests, carrier removals) airtight at negligible cost.
	LiveEffects.invalidate_compositions()
	var existing := carrier.find_status(status_id)
	if existing == null or sdata.stacking == StatusData.STACK_INDEPENDENT:
		var si := StatusInstance.make(sdata, _initial_remaining(sdata, duration), clampi(stacks, 1, sdata.max_stacks), src)
		si.bind_carrier(carrier)
		carrier.statuses.append(si)
		return
	match sdata.stacking:
		StatusData.STACK_EXTEND:
			if sdata.decay == StatusData.DECAY_DURATION and existing.remaining != -1:
				existing.remaining += _resolved_duration(sdata, duration)
		StatusData.STACK_INTENSITY:
			existing.stacks = mini(existing.stacks + stacks, sdata.max_stacks)
			existing.remaining = _refreshed_remaining(existing, sdata, duration)
		_:   # STACK_REFRESH (default)
			existing.remaining = _refreshed_remaining(existing, sdata, duration)


# The effective duration to apply: the caller's override, else the status's own default.
static func _resolved_duration(sdata: StatusData, duration: int) -> int:
	return duration if duration != Effect.STATUS_DURATION_DEFAULT else sdata.default_duration


# Initial `remaining` for a new instance: a countdown only for DECAY_DURATION; -1 (unused) for
# stack-decay / never-decay statuses, which don't use the timer.
static func _initial_remaining(sdata: StatusData, duration: int) -> int:
	if sdata.decay != StatusData.DECAY_DURATION:
		return -1
	return _resolved_duration(sdata, duration)


# Refreshed `remaining` on re-application: the longer of current and incoming for DECAY_DURATION;
# left as-is otherwise.
static func _refreshed_remaining(existing: StatusInstance, sdata: StatusData, duration: int) -> int:
	if sdata.decay != StatusData.DECAY_DURATION:
		return existing.remaining
	return _longer_duration(existing.remaining, _resolved_duration(sdata, duration))


# The longer of two durations, where -1 (whole-combat) outranks any finite count.
static func _longer_duration(a: int, b: int) -> int:
	if a == -1 or b == -1:
		return -1
	return maxi(a, b)


# A carrier's active statuses that have TRIGGERED/CUSTOM effects matching an event, grouped per
# status (so a stacked status's effects scale together, and the dispatcher can cue each status's pip
# as the container before its effects). Returns Array of { "status_id": String, "effects":
# Array[Effect], "stacks": int }.
static func triggered_groups(carrier: StatusCarrier, event_id: StringName) -> Array:
	var out: Array = []
	if carrier == null:
		return out
	for si: StatusInstance in carrier.statuses:
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


# Advances a carrier's statuses for one round phase (ON_TURN_START / ON_TURN_END): each status
# whose decay_phase matches `event` counts down (its stack count for DECAY_STACKS, else its
# `remaining` timer) and is dropped if it hits zero. Run once per carrier per phase, AFTER that
# phase's effects fire — so e.g. poison deals its damage from the current count, then the count drops.
static func advance(carrier: StatusCarrier, event_id: StringName) -> void:
	var kept: Array = []
	for si: StatusInstance in carrier.statuses:
		if _decays_on(si, event_id):
			if si.data.decay == StatusData.DECAY_STACKS:
				si.stacks -= 1
			elif si.data.decay == StatusData.DECAY_DURATION and si.remaining > 0:
				si.remaining -= 1
		if not is_expired(si):
			kept.append(si)
	carrier.statuses = kept
	# The tick is how grant-carrying statuses expire — drop the composition snapshot so the
	# next condition read sees the post-decay world (see LiveEffects).
	LiveEffects.invalidate_compositions()


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
	# 0 stacks = no status, whatever the decay mode — stacks ARE the quantity. (This is the
	# universal form of the old STACKS/INTERCEPT arm; the spread tier's shed_stack relies on
	# it for statuses whose decay mode is NONE, like burning.)
	if si.stacks <= 0:
		return true
	if si.data.decay == StatusData.DECAY_DURATION:
		return si.remaining == 0
	return false


# Sheds ONE stack off a status instance — the spread tier's "a flame dies down" — and files
# the hygiene removal if that was the last. The write lives here because carriers have no say
# and the cascade is a caller, not a writer (the same split advance already draws).
static func shed_stack(carrier: StatusCarrier, si: StatusInstance) -> void:
	si.stacks -= 1
	if carrier != null and is_expired(si):
		carrier.statuses.erase(si)
	LiveEffects.invalidate_compositions()


# (Intercept-charge spending moved into the container itself: Resolver._try_intercept
# signals the owning StatusInstance through the blind fired() channel, and the status
# spends its own DECAY_INTERCEPT charge — see StatusInstance.fired.)
