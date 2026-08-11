extends TestCase

# CombatSide: player-targeted effects (draw / discard / mana / max_mana) as Resolver
# mutations on a side object — the forms (floors, pile/hand limits, NO mana cap),
# targetless side-stat payloads (the `side` target kind is DEAD — TARGETING_DESIGN.md §10),
# interception over side mutations (allegiance vs side.owner, channel gating incl. the
# cost channel), and the authoring round-trip. See EFFECT_SYSTEM_DESIGN.md §10.


func suite_name() -> String:
	return "Combat sides"


func run() -> void:
	_draw_form()
	_discard_form()
	_mana_form()
	_max_mana_form()
	_set_forms()
	_signals()
	_effect_payload()
	_interception()
	_cost_channel()
	_authoring_roundtrip()
	_authored_content_end_to_end()


# A side with `n` units in its draw pile.
func _side_with_pile(side_owner: int, n: int) -> CombatSide:
	var s := CombatSide.make(side_owner)
	for _i in n:
		var inst := unit("pawn")
		inst.owner = side_owner
		s.draw_pile.append(inst)
	return s


func _seed_run_set(effect_dict: Dictionary, owner_kind: String, owner_id: String) -> void:
	var s := ModifierSet.new()
	s._add_owned(Effect.from_dict(effect_dict), owner_kind, owner_id)
	GameData.current_modifiers = s


func _clear_run_set() -> void:
	GameData.current_modifiers = ModifierSet.new()


func _draw_form() -> void:
	var s := _side_with_pile(0, 3)
	var out := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 2))
	check_eq(out.delta, 2, "draw 2 moves 2 cards")
	check_eq(s.hand.size(), 2, "drawn cards sit in the hand")
	check_eq(s.draw_pile.size(), 1, "the pile shrank by the same 2")
	var over := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 5))
	check_eq(over.delta, 1, "drawing past the pile stops at it (delta reports what moved)")
	var empty := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 3))
	check_eq(empty.delta, 0, "an empty pile draws nothing")
	var negative := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, -2))
	check_eq(negative.delta, 0, "a negative draw floors at 0 — never a discard")


func _discard_form() -> void:
	var s := _side_with_pile(0, 3)
	Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 3))
	var out := Resolver.submit(StatMutation.make(s, StatMutation.DISCARD, 2))
	check_eq(out.delta, 2, "discard 2 removes 2")
	check_eq(s.hand.size(), 1, "the hand shrank to 1")
	var over := Resolver.submit(StatMutation.make(s, StatMutation.DISCARD, 5))
	check_eq(over.delta, 1, "discarding past the hand stops at it")
	check_eq(s.hand.size(), 0, "hand empty")
	check_eq(Resolver.submit(StatMutation.make(s, StatMutation.DISCARD, 1)).delta, 0,
			"an empty hand discards nothing")


func _mana_form() -> void:
	var s := CombatSide.make(0)
	s.max_mana = 3
	s.mana = 3
	var gain := Resolver.submit(StatMutation.make(s, StatMutation.MANA, 2))
	check_eq(gain.delta, 2, "mana gain is UNCAPPED above max (settled: no clamp)")
	check_eq(s.mana, 5, "pool sits at 5 over a max of 3")
	var spend := Resolver.submit(StatMutation.make(s, StatMutation.MANA, -4))
	check_eq(s.mana, 1, "signed spend lands")
	check_eq(spend.delta, -4, "delta reports the landed spend")
	var floor_out := Resolver.submit(StatMutation.make(s, StatMutation.MANA, -9))
	check_eq(s.mana, 0, "mana floors at 0")
	check_eq(floor_out.delta, -1, "delta reports only what the floor allowed")


func _max_mana_form() -> void:
	var s := CombatSide.make(0)
	Resolver.submit(StatMutation.make(s, StatMutation.MAX_MANA, 3))
	check_eq(s.max_mana, 3, "max_mana is additive")
	var floor_out := Resolver.submit(StatMutation.make(s, StatMutation.MAX_MANA, -5))
	check_eq(s.max_mana, 0, "max_mana floors at 0")
	check_eq(floor_out.delta, -3, "delta reports what the floor allowed")


func _set_forms() -> void:
	var s := CombatSide.make(0)
	Resolver.set_side_max_mana(s, 4)
	Resolver.set_side_mana(s, 4)
	check(s.max_mana == 4 and s.mana == 4, "turn set-forms land as signed deltas")
	Resolver.set_side_mana(s, 2)
	check_eq(s.mana, 2, "set-form goes down too")


func _signals() -> void:
	var s := _side_with_pile(0, 2)
	var drawn_seen: Array = []
	var mana_bumps: Array = []
	s.cards_drawn.connect(func(insts: Array) -> void: drawn_seen.append_array(insts))
	s.mana_changed.connect(func() -> void: mana_bumps.append(true))
	Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 2))
	check_eq(drawn_seen.size(), 2, "cards_drawn carries the drawn instances")
	check(drawn_seen[0] is CardInstance and s.hand.has(drawn_seen[0]),
			"the presented instances ARE the hand's instances")
	Resolver.submit(StatMutation.make(s, StatMutation.MANA, 1))
	check_eq(mana_bumps.size(), 1, "mana_changed fires on a mana write")
	Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 0))
	check_eq(drawn_seen.size(), 2, "a no-op draw emits nothing")


func _ctx_with_sides(holder: CardInstance, player: CombatSide, enemy: CombatSide) -> EffectContext:
	var ctx := ctx_for(holder)
	ctx.player_side = player
	ctx.enemy_side = enemy
	return ctx


# SIDE TARGET KIND DEAD (effect-cleanse demolition): side payloads are TARGETLESS — the
# recipient derives from the holder's allegiance anchor, never from an authored target
# (TARGETING_DESIGN.md §2/§10). Opponent-directed side payloads, if ever wanted, are a
# PAYLOAD variant, not a target kind (Decision Record).


func _effect_payload() -> void:
	# The full authored path: "on play, your side draws 2" through EffectSystem.
	var player := _side_with_pile(0, 3)
	var enemy := CombatSide.make(1)
	var caster := unit("pawn")
	var eff := Effect.from_dict({"trigger": "on_play", "attribute": "draw", "amount": 2})
	var results := EffectSystem.apply_single(eff, caster, _ctx_with_sides(caster, player, enemy))
	check_eq(results.size(), 1, "one side result")
	var r: Dictionary = {} if results.is_empty() else results[0]
	check(r.get("target") == player and str(r.get("attribute", "")) == "draw"
			and int(r.get("delta", 0)) == 2, "result dict: side target, draw, delta 2")
	check_eq(player.hand.size(), 2, "the cards actually arrived")
	# Empty pile → delta 0 → no result (the no-op rule the cue system relies on).
	var dry := EffectSystem.apply_single(eff, caster,
			_ctx_with_sides(caster, CombatSide.make(0), enemy))
	var _drained := Resolver.submit(StatMutation.make(player, StatMutation.DRAW, 9))
	check(dry.is_empty(), "an empty-pile draw produces no result (no cue)")


func _interception() -> void:
	# "Your draws are doubled" — a run-set interceptor over side mutations. The target
	# participant IS the side: allegiance compares side.owner against the run anchor.
	_seed_run_set({"kind": "interceptor", "intercept": "draw",
			"of": {"participant": "target", "relation": "ally"}, "op": "mul", "amount": 2},
			"relic", "twin_lens")
	var player := _side_with_pile(0, 10)
	var enemy := _side_with_pile(1, 6)
	var out := Resolver.submit(StatMutation.make(player, StatMutation.DRAW, 2))
	check_eq(out.delta, 4, "the player's draw 2 doubles to 4")
	check(not out.interceptions.is_empty()
			and str(out.interceptions[0].get("owner_id", "")) == "twin_lens",
			"the rewrite records its owner for the cue")
	var eout := Resolver.submit(StatMutation.make(enemy, StatMutation.DRAW, 2))
	check_eq(eout.delta, 2, "the ENEMY side's draw is untouched (allegiance vs side.owner)")
	_clear_run_set()
	# Re-floor: an intercepted-away draw draws nothing, never discards.
	_seed_run_set({"kind": "interceptor", "intercept": "draw",
			"of": {"participant": "target", "relation": "ally"}, "amount": -5},
			"relic", "drought_stone")
	var dout := Resolver.submit(StatMutation.make(player, StatMutation.DRAW, 2))
	check_eq(dout.delta, 0, "a draw rewritten below 0 floors at 0")
	check_eq(player.hand.size(), 4, "no cards moved either way")
	_clear_run_set()
	# Source-participant gate still works when the TARGET is a side: a unit whose own
	# effects cause the draw boosts it (identity on the source).
	var booster := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_draw_booster", "display_name": "T",
		"cost": 1, "attack": 1, "health": 5, "speed": 1,
		"effects": [
			{"intercept": "draw",
			 "of": {"participant": "source", "relation": "self"}, "amount": 1},
		]}))
	booster.owner = 0
	var bout := Resolver.submit(StatMutation.make(player, StatMutation.DRAW, 1, booster))
	check_eq(bout.delta, 2, "a source-held interceptor boosts its own side draw (+1)")
	var other := unit("pawn")
	var oout := Resolver.submit(StatMutation.make(player, StatMutation.DRAW, 1, other))
	check_eq(oout.delta, 1, "someone else's draw is untouched (identity gate)")


func _cost_channel() -> void:
	# "Mana gains doubled" must never double SPENDING: gains ride CH_EFFECT, payments
	# ride CH_COST — the interceptor subscribes by channel.
	_seed_run_set({"kind": "interceptor", "intercept": "mana", "channel": "effect",
			"of": {"participant": "target", "relation": "ally"}, "op": "mul", "amount": 2},
			"relic", "mana_prism")
	var s := CombatSide.make(0)
	s.max_mana = 5
	s.mana = 3
	var gain := Resolver.submit(StatMutation.make(s, StatMutation.MANA, 2))
	check_eq(gain.delta, 4, "an effect-channel mana gain doubles")
	var pay := Resolver.submit(StatMutation.make(s, StatMutation.MANA, -3,
			null, StatMutation.CH_COST))
	check_eq(pay.delta, -3, "a cost-channel payment is untouched")
	_clear_run_set()


func _authoring_roundtrip() -> void:
	# A side-stat effect is targetless: it authors no targets and re-emits none.
	var d := {"trigger": "on_play", "attribute": "draw", "amount": 2}
	var eff := Effect.from_dict(d)
	var out := eff.to_dict()
	check(not out.has("targets"), "a targetless side payload re-emits no targets dict")
	check(StatMutation.is_side_stat("draw") and StatMutation.is_side_stat("max_mana")
			and not StatMutation.is_side_stat("attack"), "the side-stat vocabulary set")


func _authored_content_end_to_end() -> void:
	# The REAL shipped data: darkness_pawn's on-death draw (card tier) and the Reaper's
	# Ledger relic (run tier, through the REAL ModifierSet.for_run build) — proves the
	# authored JSON works, not just in-test dicts.
	var player := _side_with_pile(0, 6)
	var enemy_side := CombatSide.make(1)
	var pawn := unit("darkness_pawn")
	var ctx := _ctx_with_sides(pawn, player, enemy_side)
	var results := EffectSystem.trigger(GameEvent.make(&"death", pawn), pawn, ctx)
	check_eq(player.hand.size(), 1, "darkness_pawn (authored JSON): its own death draws 1")
	check_eq(results.size(), 1, "…reported as one side result")

	var run := RunData.from_dict({})
	run.relics = ["reapers_ledger"]
	GameData.current_modifiers = ModifierSet.for_run(ProfileData.from_dict({}), run)
	var knight := unit("darkness_knight")
	var kctx := _ctx_with_sides(knight, player, enemy_side)
	kctx.subject = knight
	var rres := EffectSystem.trigger_global(GameEvent.make(&"death", knight), kctx)
	check_eq(player.hand.size(), 2, "Reaper's Ledger (authored JSON): a darkness death draws 1")
	check(not rres.is_empty(), "…via the run tier")
	# The composition gate: a plain pawn's death feeds no Ledger.
	var plain := unit("pawn")
	var pctx := _ctx_with_sides(plain, player, enemy_side)
	pctx.subject = plain
	var pres := EffectSystem.trigger_global(GameEvent.make(&"death", plain), pctx)
	check(pres.is_empty() and player.hand.size() == 2,
			"a non-darkness death draws nothing (subject_elements gate)")
	_clear_run_set()
