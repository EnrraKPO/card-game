extends TestCase

# Status lifecycle riding the Resolver-era pipeline: Blind end-to-end on the pending-mutation
# path, poison's stack-decay tick, a modifier status folding at read time, and duration expiry.


func suite_name() -> String:
	return "Statuses"


func run() -> void:
	_blind_end_to_end()
	_barrier()
	_poison_tick_and_decay()
	_modifier_status_and_expiry()


func _barrier() -> void:
	# Barrier: target-role block, spent only when it actually stops something.
	var tgt := unit("rook")   # 6 HP, 3 shield
	tgt.apply_status("barrier", Effect.STATUS_DURATION_DEFAULT, 1, null)
	var atk := unit("pawn")
	var out := Resolver.submit(StatMutation.damage(tgt, 5, atk))
	check_eq(out.delta, 0, "barrier blocks a damaging strike outright")
	check_eq(tgt.current_shield, 3, "blocked strike never reaches the shield")
	check(tgt.find_status("barrier") == null, "barrier is consumed by the block")
	check(not out.interceptions.is_empty()
			and str(out.interceptions[0].get("owner_id", "")) == "barrier",
			"the block records barrier for the pip cue")

	# A 0-damage whiff spends nothing and cues nothing.
	tgt.apply_status("barrier", Effect.STATUS_DURATION_DEFAULT, 1, null)
	var whiff := Resolver.submit(StatMutation.damage(tgt, 0, atk))
	check_eq(whiff.delta, 0, "a whiff lands 0 either way")
	check(whiff.interceptions.is_empty(), "a whiff records no interception (no phantom cue)")
	check(tgt.find_status("barrier") != null, "a whiff doesn't spend the barrier")

	# A Blinded attacker's miss (source-side block zeroes the strike first): barrier untouched.
	var blinded := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_sure_blind", "display_name": "T",
		"cost": 1, "attack": 4, "health": 3, "speed": 1,
		"effects": [
			{"intercept": "damage", "channel": "attack", "role": "source", "op": "mul", "amount": 0},
		]}))
	blinded.owner = 0
	var missed := Resolver.submit(StatMutation.damage(tgt, 4, blinded))
	check_eq(missed.delta, 0, "the blinded strike still lands 0")
	check_eq(missed.interceptions.size(), 1, "only the source-side block fires (barrier stays silent)")
	check(tgt.find_status("barrier") != null, "a blinded miss doesn't spend the barrier")

	# Stacked barrier = that many blocks: one charge per stopped strike.
	var tgt2 := unit("rook")
	tgt2.apply_status("barrier", Effect.STATUS_DURATION_DEFAULT, 2, null)
	Resolver.submit(StatMutation.damage(tgt2, 4, atk))
	var si := tgt2.find_status("barrier")
	check(si != null and si.stacks == 1, "a 2-charge barrier survives the first block with 1 left")
	Resolver.submit(StatMutation.damage(tgt2, 4, atk))
	check(tgt2.find_status("barrier") == null, "the second block spends the last charge")
	var third := Resolver.submit(StatMutation.damage(tgt2, 4, atk))
	check_eq(third.delta, -4, "the third strike lands in full")


func _blind_end_to_end() -> void:
	# Statistical: Blind is a status-carried INTERCEPTOR — its 50% roll happens inside
	# Resolver.submit, per strike; a charge is spent per attack (hit or miss) via the
	# submit-then-advance order combat uses. Loose bounds — it's an RNG test.
	var trials := 400
	var blocked := 0
	var charge_leak := false
	var cue_missing := false
	for i in trials:
		var atk := unit("pawn")
		atk.apply_status("blind", Effect.STATUS_DURATION_DEFAULT, 1, null)
		var tgt := unit("pawn")
		var out := Resolver.submit(StatMutation.damage(tgt, 4, atk))
		if out.delta == 0:
			blocked += 1
			# A status-owned interception must name its status so combat can glint the pip.
			if out.interceptions.is_empty() \
					or str(out.interceptions[0].get("owner_id", "")) != "blind":
				cue_missing = true
		StatusEngine.advance(atk, &"attack")
		if atk.find_status("blind") != null:
			charge_leak = true
	check(not charge_leak, "blind charge is spent after one attack, hit or miss")
	check(not cue_missing, "blocked strikes record blind as the intercepting status (pip cue)")
	var rate := float(blocked) / float(trials)
	check(rate > 0.35 and rate < 0.65,
			"blind blocks ~50%% of strikes (got %d/%d)" % [blocked, trials])


func _poison_tick_and_decay() -> void:
	# Poison is authored on the ACTIVATE phase (the unit's own turn in the combat order) —
	# not turn_start; see data/statuses/poison.json.
	var u := unit("rook")
	u.apply_status("poison", Effect.STATUS_DURATION_DEFAULT, 3, null)
	var hp0 := u.current_health
	EffectSystem.trigger(GameEvent.make(&"activate", u), u, ctx_for(u))
	check_eq(u.current_health, hp0 - 3, "poison ticks its CURRENT stack count (3), bypassing shield")
	check_eq(u.current_shield, CardData.get_card("rook").shield, "poison never touches shield")
	StatusEngine.advance(u, &"activate")
	var si := u.find_status("poison")
	check(si != null and si.stacks == 2, "poison decays one stack AFTER ticking")


func _modifier_status_and_expiry() -> void:
	var u := unit("pawn")
	var atk0 := u.get_attribute("attack")
	u.apply_status("empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check_eq(u.get_attribute("attack"), atk0 + 2, "empowered's modifier folds at read time")

	# default_duration 2, turn_end decay: two round-ends and it falls off — buff gone.
	StatusEngine.advance(u, &"turn_end")
	check(u.find_status("empowered") != null, "empowered survives its first round-end")
	StatusEngine.advance(u, &"turn_end")
	check(u.find_status("empowered") == null, "empowered expires after its duration")
	check_eq(u.get_attribute("attack"), atk0, "expired status stops folding — no teardown needed")
