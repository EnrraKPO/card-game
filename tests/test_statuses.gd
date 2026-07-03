extends TestCase

# Status lifecycle riding the Resolver-era pipeline: Blind end-to-end on the pending-mutation
# path, poison's stack-decay tick, a modifier status folding at read time, and duration expiry.


func suite_name() -> String:
	return "Statuses"


func run() -> void:
	_blind_end_to_end()
	_poison_tick_and_decay()
	_modifier_status_and_expiry()


func _blind_end_to_end() -> void:
	# Statistical: Blind's 50% roll happens per attack; a charge is spent per attack (hit or
	# miss) via the fire-then-advance order combat uses. Loose bounds — it's an RNG test.
	var trials := 400
	var blocked := 0
	var charge_leak := false
	for i in trials:
		var atk := unit("pawn")
		atk.apply_status("blind", Effect.STATUS_DURATION_DEFAULT, 1, null)
		var ctx := ctx_for(atk)
		ctx.pending = StatMutation.damage(atk, 4, atk)
		EffectSystem.trigger(Effect.Trigger.ON_ATTACK, atk, ctx)
		if ctx.pending.amount == 0:
			blocked += 1
		StatusEngine.advance(atk, Effect.Trigger.ON_ATTACK)
		if atk.find_status("blind") != null:
			charge_leak = true
	check(not charge_leak, "blind charge is spent after one attack, hit or miss")
	var rate := float(blocked) / float(trials)
	check(rate > 0.35 and rate < 0.65,
			"blind blocks ~50%% of strikes (got %d/%d)" % [blocked, trials])


func _poison_tick_and_decay() -> void:
	# Poison is authored on the ACTIVATE phase (the unit's own turn in the combat order) —
	# not turn_start; see data/statuses/poison.json.
	var u := unit("rook")
	u.apply_status("poison", Effect.STATUS_DURATION_DEFAULT, 3, null)
	var hp0 := u.current_health
	EffectSystem.trigger(Effect.Trigger.ON_ACTIVATE, u, ctx_for(u))
	check_eq(u.current_health, hp0 - 3, "poison ticks its CURRENT stack count (3), bypassing shield")
	check_eq(u.current_shield, CardData.get_card("rook").shield, "poison never touches shield")
	StatusEngine.advance(u, Effect.Trigger.ON_ACTIVATE)
	var si := u.find_status("poison")
	check(si != null and si.stacks == 2, "poison decays one stack AFTER ticking")


func _modifier_status_and_expiry() -> void:
	var u := unit("pawn")
	var atk0 := u.get_attribute("attack")
	u.apply_status("empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check_eq(u.get_attribute("attack"), atk0 + 2, "empowered's modifier folds at read time")

	# default_duration 2, turn_end decay: two round-ends and it falls off — buff gone.
	StatusEngine.advance(u, Effect.Trigger.ON_TURN_END)
	check(u.find_status("empowered") != null, "empowered survives its first round-end")
	StatusEngine.advance(u, Effect.Trigger.ON_TURN_END)
	check(u.find_status("empowered") == null, "empowered expires after its duration")
	check_eq(u.get_attribute("attack"), atk0, "expired status stops folding — no teardown needed")
