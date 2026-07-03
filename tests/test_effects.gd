extends TestCase

# The effect pipeline riding the Resolver: the three stat-write paths behave exactly as they
# did pre-Resolver (heal clamp + landed-delta results, shield-first damage_taken, modifiers),
# plus pending-mutation arbitration (Blind's block form, armor, clamping, no-op safety).


func suite_name() -> String:
	return "Effects & Arbitration"


func run() -> void:
	_effect_write_paths()
	_arbitration()
	_op_round_trip()


func _effect_write_paths() -> void:
	var u := unit("rook")   # 6 HP, 3 shield
	var ctx := ctx_for(u)

	var dmg_eff := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "damage_taken", "amount": 4})
	EffectSystem.apply_single(dmg_eff, u, ctx)
	check_eq(u.current_shield, 0, "effect damage_taken resolves shield-first (3 absorbed)")
	check_eq(u.current_health, 5, "effect damage_taken bleeds the remainder (1)")

	var heal_eff := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "health", "amount": 99})
	var res := EffectSystem.apply_single(heal_eff, u, ctx)
	check_eq(u.current_health, 6, "effect heal clamps to max via Resolver")
	check(not res.is_empty() and int(res[0].get("delta", -1)) == 1,
			"heal result carries the LANDED delta (1)")
	check(EffectSystem.apply_single(heal_eff, u, ctx).is_empty(),
			"heal at full HP yields no result — no phantom cue")

	var poison_eff := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "health", "amount": -2})
	var pres := EffectSystem.apply_single(poison_eff, u, ctx)
	check_eq(u.current_health, 4, "negative health effect bypasses shield")
	check(not pres.is_empty() and int(pres[0].get("delta", 1)) == -2,
			"direct damage result reports its delta")

	var atk0 := u.get_attribute("attack")
	var buff := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "attack", "amount": 2})
	EffectSystem.apply_single(buff, u, ctx)
	check_eq(u.get_attribute("attack"), atk0 + 2, "modifier effect folds via Resolver")


func _arbitration() -> void:
	var u := unit("pawn")
	var ctx := ctx_for(u)

	var block := Effect.from_dict({"trigger": "on_attack", "targeting_policy": "self",
			"attribute": "outgoing_damage", "op": "mul", "amount": 0})
	ctx.pending = StatMutation.damage(u, 5, u)
	var bres := EffectSystem.apply_single(block, u, ctx)
	check_eq(ctx.pending.amount, 0, "mul-0 blocks the pending strike (5 -> 0)")
	check(not bres.is_empty(), "a pending rewrite returns a result (for the pip cue)")

	# Two block sources in the same moment: still just 0, and a LATER strike is untouched
	# (nothing persists — the stale-counter bug class is impossible by construction).
	ctx.pending = StatMutation.damage(u, 6, u)
	EffectSystem.apply_single(block, u, ctx)
	EffectSystem.apply_single(block, u, ctx)
	check_eq(ctx.pending.amount, 0, "double block is still just 0")
	check_eq(StatMutation.damage(u, 6, u).amount, 6, "a fresh strike carries no residue")

	var armor := Effect.from_dict({"trigger": "on_attack", "targeting_policy": "self",
			"attribute": "incoming_damage", "amount": -3})
	ctx.pending = StatMutation.damage(u, 5, null)
	EffectSystem.apply_single(armor, u, ctx)
	check_eq(ctx.pending.amount, 2, "armor (add -3) shaves the pending strike (5 -> 2)")
	ctx.pending = StatMutation.damage(u, 2, null)
	EffectSystem.apply_single(armor, u, ctx)
	check_eq(ctx.pending.amount, 0, "over-armor clamps at 0 — never flips into a heal")

	ctx.pending = null
	check(EffectSystem.apply_single(armor, u, ctx).is_empty(),
			"arbitration without a pending mutation is a silent no-op")


func _op_round_trip() -> void:
	var block := Effect.from_dict({"trigger": "on_attack", "targeting_policy": "self",
			"attribute": "outgoing_damage", "op": "mul", "amount": 0})
	var rt := Effect.from_dict(block.to_dict())
	check(rt.op == Effect.Op.MUL and rt.attribute == "outgoing_damage",
			"triggered effect round-trips with op=mul intact")
