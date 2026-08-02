extends TestCase

# Universal interception: any active container's INTERCEPTOR effects rewrite pending
# mutations — the run set (relics/upgrades) included, matched relationally (participant +
# identity/conditions) instead of the old holder-role gate. Also covers the STATUS mutation
# form (status application routed through the Resolver, so stack counts are interceptable)
# and the MUTATION-form condition (predicates over the pending mutation, e.g. "heals only").


func suite_name() -> String:
	return "Interception"


func run() -> void:
	_run_scope_damage_reduction()
	_heal_boost()
	_status_stack_bonus()
	_status_intercepted_away()
	_relational_matching()
	_composition_gated_intercept()
	_legacy_roundtrip()
	_native_roundtrip()
	_authored_content_end_to_end()
	_split_portion_gates()
	_portion_no_reflow()


func _split_portion_gates() -> void:
	# A hit's shield/health shares run their OWN interception pass after the total settles
	# (stat shield_pool / health, on the hit's channel) — the "damage that would reach
	# Health" vocabulary. Authored end-to-end: Stalwart Barrier blocks the health share,
	# lets absorption pass, and spends a charge only when it actually blocked.
	var atk := unit("pawn")
	atk.owner = 1
	var tgt := unit("rook")   # 6 HP, 3 base shield
	StatusEngine.apply(tgt, "stalwart_barrier", Effect.STATUS_DURATION_DEFAULT, 2, null)
	# stacks are block CHARGES; the standing +1 is flat while held (container tracker)
	check_eq(tgt.current_shield, 4, "stalwart folds a flat +1 onto the pool")
	# Fully absorbed: the health share is 0 — nothing rewritten, no charge spent.
	var absorbed := Resolver.submit(StatMutation.damage(tgt, 3, atk))
	check_eq(absorbed.shield_absorbed, 3, "shield eats the whole hit")
	check_eq(absorbed.health_damage, 0, "nothing reaches health")
	var si := tgt.find_status("stalwart_barrier")
	check(si != null and si.stacks == 2, "an absorbed hit spends NO stalwart charge")
	# Piercing: pool 1 vs 4 damage → shares 1 shield / 3 health; the health share is
	# rewritten to 0, absorption passes through untouched.
	var pierced := Resolver.submit(StatMutation.damage(tgt, 4, atk))
	check_eq(pierced.shield_absorbed, 1, "the shield share commits as split")
	check_eq(pierced.health_damage, 0, "the health share is blocked by the portion gate")
	check_eq(tgt.current_health, 6, "no wound landed")
	si = tgt.find_status("stalwart_barrier")
	check(si != null and si.stacks == 1, "the block spends one charge")
	check(pierced.interceptions.size() == 1
			and str(pierced.interceptions[0].get("owner_id", "")) == "stalwart_barrier",
			"the portion rewrite is recorded for presentation")


func _portion_no_reflow() -> void:
	# Portions never redistribute: sparing the shield does not enlarge the wound. A
	# run-scope interceptor zeroes the shield share; the health share stays as split.
	_seed_run_set({"kind": "interceptor", "intercept": "shield_pool", "channel": "attack",
			"of": {"participant": "target", "relation": "ally"}, "op": "mul", "amount": 0},
			"relic", "aegis_lacquer")
	var atk := unit("pawn")
	atk.owner = 1
	var mine := unit("rook")   # 3 shield
	var hit := Resolver.submit(StatMutation.damage(mine, 4, atk))
	check_eq(hit.shield_absorbed, 0, "the shield share is intercepted away")
	check_eq(mine.current_shield, 3, "the pool is untouched")
	check_eq(hit.health_damage, 1, "the health share stays as split (no re-flow)")
	_clear_run_set()


# Seeds the run set with one owned interceptor effect; caller MUST _clear_run_set() after.
func _seed_run_set(effect_dict: Dictionary, owner_kind: String, owner_id: String) -> void:
	var s := ModifierSet.new()
	s._add_owned(Effect.from_dict(effect_dict), owner_kind, owner_id)
	GameData.current_modifiers = s


func _clear_run_set() -> void:
	GameData.current_modifiers = ModifierSet.new()


func _run_scope_damage_reduction() -> void:
	# The Bulwark upgrade: "all your units take 1 less attack damage" — a holderless
	# run-scope interceptor gated by participant target + allegiance ally.
	_seed_run_set({"kind": "interceptor", "intercept": "damage", "channel": "attack",
			"of": {"participant": "target", "relation": "ally"}, "amount": -1},
			"upgrade", "war_bulwark")
	var enemy := unit("pawn")
	enemy.owner = 1
	var mine := unit("pawn")
	var out := Resolver.submit(StatMutation.damage(mine, 3, enemy))
	check_eq(out.delta, -2, "run-scope interceptor shaves 1 off damage to an allied unit")
	check(not out.interceptions.is_empty()
			and str(out.interceptions[0].get("owner_kind", "")) == "upgrade"
			and str(out.interceptions[0].get("owner_id", "")) == "war_bulwark"
			and out.interceptions[0].get("holder") == null,
			"the rewrite records its run-scope owner (holderless)")
	var back := Resolver.submit(StatMutation.damage(enemy, 3, mine))
	check_eq(back.delta, -3, "an enemy unit gets no reduction (allegiance gate)")
	_clear_run_set()


func _heal_boost() -> void:
	# Mender's Charm: +1 to positive HEALTH mutations from an allied source — the
	# MUTATION-form condition (amount > 0) keeps poison and wounds out of reach.
	_seed_run_set({"kind": "interceptor", "intercept": "health",
			"of": {"participant": "source", "relation": "ally"},
			"conditions": [{"mutation": "amount", "comparator": "gt", "value": 0}],
			"amount": 1}, "relic", "menders_charm")
	var healer := unit("pawn")
	var tgt := unit("rook")
	Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, -4, null))   # wound first
	var healed := Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, 2, healer))
	check_eq(healed.delta, 3, "an allied heal lands +1 (2 -> 3)")
	var poisoned := Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, -2, healer))
	check_eq(poisoned.delta, -2, "a direct wound is untouched (mutation-form condition)")
	var enemy := unit("pawn")
	enemy.owner = 1
	var enemy_heal := Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, 2, enemy))
	check_eq(enemy_heal.delta, 2, "an enemy-sourced heal gets no boost (allegiance gate)")
	Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, -1, null))
	var sys_heal := Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, 1, null,
			StatMutation.CH_SYSTEM))
	check_eq(sys_heal.delta, 1, "a system heal (null source) never matches a source gate")
	# The effect path SURFACES the records: a heal driven through EffectSystem carries the
	# rewriter on its result dict, so presentation can cue the relic chip (glint fix).
	Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, -3, null))
	var heal_eff := Effect.from_dict({"trigger": "on_play", "targeting_policy": "manual",
			"attribute": "health", "amount": 2})
	var hctx := ctx_for(healer)
	hctx.manual_target = tgt
	var hres := EffectSystem.apply_single(heal_eff, healer, hctx)
	var hrec: Dictionary = {} if hres.is_empty() else hres[0]
	var hints: Array = hrec.get("interceptions", [])
	check(not hints.is_empty()
			and str((hints[0] as Dictionary).get("owner_kind", "")) == "relic"
			and str((hints[0] as Dictionary).get("owner_id", "")) == "menders_charm",
			"effect-path results carry the interception record for the relic cue")
	_clear_run_set()


func _status_stack_bonus() -> void:
	# Contagion Stone: status application rides the Resolver now; an ally-sourced
	# application gets +1 stack rewritten in-flight.
	_seed_run_set({"kind": "interceptor", "intercept": "status",
			"of": {"participant": "source", "relation": "ally"}, "amount": 1},
			"relic", "contagion_stone")
	var src := unit("pawn")
	var enemy := unit("pawn")
	enemy.owner = 1
	var out := Resolver.submit(StatMutation.status_apply(
			enemy, "poison", Effect.STATUS_DURATION_DEFAULT, 1, src))
	check_eq(out.delta, 2, "an ally-applied status gains +1 stack (1 -> 2)")
	var si := enemy.find_status("poison")
	check(si != null and si.stacks == 2, "the extra stack actually landed")
	var mine := unit("pawn")
	var esrc := unit("pawn")
	esrc.owner = 1
	Resolver.submit(StatMutation.status_apply(
			mine, "poison", Effect.STATUS_DURATION_DEFAULT, 1, esrc))
	var mi := mine.find_status("poison")
	check(mi != null and mi.stacks == 1, "an enemy-applied status gets no bonus")
	# max_stacks clamping still holds inside StatusEngine.apply (barrier caps at 9).
	var tgt2 := unit("rook")
	Resolver.submit(StatMutation.status_apply(
			tgt2, "barrier", Effect.STATUS_DURATION_DEFAULT, 9, src))
	var bi := tgt2.find_status("barrier")
	check(bi != null and bi.stacks == 9, "max_stacks clamp holds against the bonus")
	_clear_run_set()


func _status_intercepted_away() -> void:
	# An application multiplied to 0 applies nothing, reports delta 0, and the effect-side
	# cue reflects that (EffectSystem returns no result for it).
	_seed_run_set({"kind": "interceptor", "intercept": "status",
			"of": {"participant": "source", "relation": "ally"}, "op": "mul", "amount": 0},
			"relic", "_test_null_stone")
	var src := unit("pawn")
	var tgt := unit("pawn")
	tgt.owner = 1
	var out := Resolver.submit(StatMutation.status_apply(
			tgt, "poison", Effect.STATUS_DURATION_DEFAULT, 2, src))
	check_eq(out.delta, 0, "an intercepted-away application reports delta 0")
	check(tgt.find_status("poison") == null, "and applies nothing")
	var eff := Effect.from_dict({"trigger": "on_play", "targeting_policy": "manual",
			"status": {"id": "poison", "stacks": 1}})
	var ctx := ctx_for(src)
	ctx.manual_target = tgt
	var results := EffectSystem.apply_single(eff, src, ctx)
	check(results.is_empty(), "EffectSystem reports no result for a nulled application (no cue)")
	_clear_run_set()


func _relational_matching() -> void:
	# A unit-held native interceptor: participant + relation, no identity — the holder
	# guards itself ("this unit takes 1 less damage" spelled relationally).
	var guard := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_guard", "display_name": "T",
		"cost": 1, "attack": 2, "health": 9, "speed": 1,
		"effects": [
			{"intercept": "damage", "channel": "attack",
			 "of": {"participant": "target", "relation": "ally"}, "amount": -1},
		]}))
	guard.owner = 0
	var enemy := unit("pawn")
	enemy.owner = 1
	var out := Resolver.submit(StatMutation.damage(guard, 3, enemy))
	check_eq(out.delta, -2, "target-ally relation matches the holder as its own target")
	# The same holder ATTACKING: the participant (target) is an enemy — relation fails,
	# outgoing damage is untouched.
	var out2 := Resolver.submit(StatMutation.damage(enemy, 2, guard))
	check_eq(out2.delta, -2, "the ally gate never rewrites damage dealt TO an enemy")
	# Identity (of.relation self ≡ legacy role): fires only when the participant IS the holder.
	var selfish := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_selfish", "display_name": "T",
		"cost": 1, "attack": 2, "health": 9, "speed": 1,
		"effects": [
			{"intercept": "damage", "channel": "attack",
			 "of": {"participant": "target", "relation": "self"}, "amount": -1},
		]}))
	selfish.owner = 0
	var hit := Resolver.submit(StatMutation.damage(selfish, 3, enemy))
	check_eq(hit.delta, -2, "identity gate fires when the holder is the mutation's target")


func _composition_gated_intercept() -> void:
	# Unit-form conditions gate the participant: "your PAWN units take 1 less damage".
	_seed_run_set({"kind": "interceptor", "intercept": "damage", "channel": "attack",
			"of": {"participant": "target", "relation": "ally"},
			"conditions": [{"composition": ["pawn"]}], "amount": -1},
			"upgrade", "_test_pawn_guard")
	var enemy := unit("pawn")
	enemy.owner = 1
	var pawn := unit("pawn")
	var out := Resolver.submit(StatMutation.damage(pawn, 3, enemy))
	check_eq(out.delta, -2, "a pawn target passes the composition condition")
	var rook := unit("rook")
	var out2 := Resolver.submit(StatMutation.damage(rook, 3, enemy))
	check_eq(out2.delta, -3, "a rook target fails it — no rewrite")
	_clear_run_set()


func _legacy_roundtrip() -> void:
	# The trigger-migration rule: legacy in → legacy out, byte-faithful; behavior identical
	# (legacy role maps to participant + structural identity).
	# (to_dict has always emitted `amount` as float — expectations use 0.0 accordingly.)
	var blind := {"intercept": "damage", "channel": "attack", "role": "source",
			"op": "mul", "amount": 0.0, "chance": 0.5}
	check_eq(Effect.from_dict(blind).to_dict(), blind, "blind's legacy dict round-trips")
	var barrier := {"intercept": "damage", "channel": "attack", "role": "target",
			"op": "mul", "amount": 0.0}
	check_eq(Effect.from_dict(barrier).to_dict(), barrier, "barrier's legacy dict round-trips")
	var e := Effect.from_dict(barrier)
	check(e.intercept_participant == "target" and e.intercept_identity,
			"legacy role maps to participant + identity")


func _native_roundtrip() -> void:
	# Native in → native out; of.relation ally converges onto an allegiance condition
	# (one grammar, one canonical spelling) while identity keeps its structural place.
	var d := {"kind": "interceptor", "intercept": "health",
			"of": {"participant": "source", "relation": "ally"},
			"conditions": [{"mutation": "amount", "comparator": "gt", "value": 0}],
			"amount": 1}
	var out := Effect.from_dict(d).to_dict()
	check_eq(str((out.get("of", {}) as Dictionary).get("participant", "")), "source",
			"native form keeps its participant")
	var conds: Array = out.get("conditions", [])
	check_eq(conds.size(), 2, "of.relation ally converged into the conditions list")
	check(conds.any(func(c: Variant) -> bool:
			return str((c as Dictionary).get("allegiance", "")) == "ally"),
			"…as an allegiance condition")
	check(conds.any(func(c: Variant) -> bool:
			return str((c as Dictionary).get("mutation", "")) == "amount"),
			"…alongside the authored mutation-form condition")
	# Reparse of the emitted form is semantically identical.
	var e2 := Effect.from_dict(out)
	check(e2.intercept_participant == "source" and not e2.intercept_identity
			and e2.conditions.size() == 2, "the emitted form reparses identically")


func _authored_content_end_to_end() -> void:
	# The REAL authored content, through the REAL run-set build (ModifierSet.for_run with a
	# run owning the relics + a profile owning the upgrade) — proves the shipped JSON works,
	# not just in-test dicts.
	var profile := ProfileData.from_dict({})
	profile.owned_upgrades.append("war_bulwark")
	var run := RunData.from_dict({})
	run.relics = ["menders_charm", "contagion_stone"]
	GameData.current_modifiers = ModifierSet.for_run(profile, run)

	var enemy := unit("pawn")
	enemy.owner = 1
	var mine := unit("rook")
	var hit := Resolver.submit(StatMutation.damage(mine, 3, enemy))
	check_eq(hit.delta, -2, "Bulwark (authored JSON): my unit takes 1 less attack damage")

	Resolver.submit(StatMutation.make(mine, StatMutation.HEALTH, -4, null))
	var healer := unit("pawn")
	var heal := Resolver.submit(StatMutation.make(mine, StatMutation.HEALTH, 2, healer))
	check_eq(heal.delta, 3, "Mender's Charm (authored JSON): my heal restores +1")

	Resolver.submit(StatMutation.status_apply(
			enemy, "poison", Effect.STATUS_DURATION_DEFAULT, 1, healer))
	var si := enemy.find_status("poison")
	check(si != null and si.stacks == 2,
			"Contagion Stone (authored JSON): my status application gains +1 stack")
	_clear_run_set()
