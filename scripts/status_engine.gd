class_name StatusEngine
extends RefCounted

# The operator for Statuses — ALL the rules of status behavior, so carriers (units, slots —
# see GameEntity) hold their list and have zero say:
#   • apply    — the one application writer: stacking policy, clamping, refresh.
#   • advance  — the per-round countdown: decrement, drop expired.
# This lifecycle machinery stays as-is through the effect-layer rebuild (user ruling
# 2026-08-11: out of that initiative's scope). What a status CARRIES is the rebuilt
# structures' business. See StatusData, StatusInstance, GameEntity.


# The "no duration override" sentinel: apply() falls back to the status's own default.
const DURATION_DEFAULT := -9999


# Applies a status (by id) to a carrier, combining with an existing one of the same id per the
# status's stacking rule. `duration` defaults to the status's own (pass to override); a status
# whose kind is "combat" always lasts the whole fight regardless. See StatusData.
static func apply(carrier: GameEntity, status_id: String, duration: int = DURATION_DEFAULT, stacks: int = 1, src: CardInstance = null) -> void:
	if carrier == null:
		return
	var sdata := StatusData.get_status(status_id)
	if sdata == null:
		return
	# Status storage write — a status may carry composition grants (see LiveEffects). The
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
	return duration if duration != DURATION_DEFAULT else sdata.default_duration


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


# (triggered_groups — the per-status dispatch feed — died with the effect dispatcher,
# 2026-08-11. The rebuilt dispatch enumerates a carrier's status-held TriggeredEffects
# grouped per status, so a stacked status's contributions scale together and the pip cues
# as the container before its results.)


# Advances a carrier's statuses for one round phase (ON_TURN_START / ON_TURN_END): each status
# whose decay_phase matches `event` counts down (its stack count for DECAY_STACKS, else its
# `remaining` timer) and is dropped if it hits zero. Run once per carrier per phase, AFTER that
# phase's effects fire — so e.g. poison deals its damage from the current count, then the count drops.
static func advance(carrier: GameEntity, event_id: StringName) -> void:
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


static func _decays_on(si: StatusInstance, event_id: StringName) -> bool:
	# NONE never decays; INTERCEPT decays only via consume_interception (not phase-driven).
	if si.data.decay == StatusData.DECAY_NONE or si.data.decay == StatusData.DECAY_INTERCEPT:
		return false
	match si.data.decay_phase:
		StatusData.PHASE_TURN_START: return event_id == &"turn_start"
		StatusData.PHASE_ACT:        return event_id == &"act"
		StatusData.PHASE_ATTACK:     return event_id == &"attack"
		_:                           return event_id == &"turn_end"


# Whether a status instance's decay state says it is over. Public: StatusInstance.exists()
# (the tracker existence probe) pull-checks this on every read — removal is hygiene only.
static func is_expired(si: StatusInstance) -> bool:
	# 0 stacks = no status, whatever the decay mode — stacks ARE the quantity. (This is the
	# universal form of the old STACKS/INTERCEPT arm.)
	if si.stacks <= 0:
		return true
	if si.data.decay == StatusData.DECAY_DURATION:
		return si.remaining == 0
	return false


# Sheds ONE stack off a status instance and files the hygiene removal if that was the last.
# The write lives here because carriers have no say and a cascade is a caller, not a writer
# (the same split advance already draws).
static func shed_stack(carrier: GameEntity, si: StatusInstance) -> void:
	si.stacks -= 1
	if carrier != null and is_expired(si):
		carrier.statuses.erase(si)


# (Intercept-charge spending moved into the container itself: Resolver._try_intercept
# signals the owning StatusInstance through the blind fired() channel, and the status
# spends its own DECAY_INTERCEPT charge — see StatusInstance.fired.)
