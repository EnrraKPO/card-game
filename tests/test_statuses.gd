extends TestCase

# Status LIFECYCLE only — the StatusEngine machinery: application, stacking policies,
# decay modes, phase timing, and expiry. This system stays as-is through the effect-layer
# rebuild (user ruling 2026-08-11: statuses machinery is out of the effect layer's scope).
#
# Deliberately absent: anything a status CARRIES (standing folds, interceptors, periodic
# ticks) — that is effect-layer behavior, banished with the old machinery; the rebuild's
# own suites cover it when statuses hold the new structures.


func suite_name() -> String:
	return "Statuses"


const HOLD := "_t_hold"   # injected: decay none, stacking stack — the plain lifecycle fixture


func run() -> void:
	StatusData._all[HOLD] = StatusData.from_dict({
		"id": HOLD, "decay": "none", "stacking": "stack"})
	_duration_expiry()
	_stack_decay_timing()
	_stack_accumulation()
	_zero_stacks_is_expired_whatever_the_decay()
	StatusData._all.erase(HOLD)


func _duration_expiry() -> void:
	# Empowered: default_duration 2, turn_end decay — two round-ends and it falls off.
	var u := unit("pawn")
	StatusEngine.apply(u, "empowered", StatusEngine.DURATION_DEFAULT, 1, null)
	check(u.find_status("empowered") != null, "a duration status applies")
	StatusEngine.advance(u, &"turn_end")
	check(u.find_status("empowered") != null, "empowered survives its first round-end")
	StatusEngine.advance(u, &"turn_end")
	check(u.find_status("empowered") == null, "empowered expires after its duration")


func _stack_decay_timing() -> void:
	# Poison decays by STACK COUNT on the unit's own act moment — and only that moment.
	var u := unit("rook")
	StatusEngine.apply(u, "poison", StatusEngine.DURATION_DEFAULT, 3, null)
	StatusEngine.advance(u, &"turn_end")
	var si := u.find_status("poison")
	check(si != null and si.stacks == 3, "an off-phase moment decays nothing")
	StatusEngine.advance(u, &"act")
	si = u.find_status("poison")
	check(si != null and si.stacks == 2, "poison decays one stack at its own act")
	StatusEngine.advance(u, &"act")
	StatusEngine.advance(u, &"act")
	check(u.find_status("poison") == null, "the last stack's decay removes the status")


func _stack_accumulation() -> void:
	# stacking "stack": re-application piles on; decay-none piles never shrink on their own.
	var u := unit("pawn")
	StatusEngine.apply(u, HOLD, StatusEngine.DURATION_DEFAULT, 3, null)
	StatusEngine.advance(u, &"turn_end")
	var si := u.find_status(HOLD)
	check(si != null and si.stacks == 3, "a decay-none status never wears off on its own")
	StatusEngine.apply(u, HOLD, StatusEngine.DURATION_DEFAULT, 2, null)
	si = u.find_status(HOLD)
	check(si != null and si.stacks == 5, "re-applying a stacking status accumulates (3+2)")


func _zero_stacks_is_expired_whatever_the_decay() -> void:
	# 0 stacks = no status, whatever the decay mode — stacks ARE the quantity.
	var u := unit("pawn")
	StatusEngine.apply(u, HOLD, StatusEngine.DURATION_DEFAULT, 1, null)
	var si := u.find_status(HOLD)
	check(si != null and not StatusEngine.is_expired(si), "one stack of a decay-none status lives")
	StatusEngine.shed_stack(u, si)
	check(StatusEngine.is_expired(si), "0 stacks = expired, even at decay none")
	check(u.find_status(HOLD) == null, "shed_stack files the hygiene removal itself")
