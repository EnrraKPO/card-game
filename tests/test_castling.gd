extends TestCase

# The Castling card (rook-generated Barrier spell): generation fallback, pool exclusion, and
# the cast granting Barrier to every ally.


func suite_name() -> String:
	return "Castling & rook generation"


func run() -> void:
	var castling := CardData.get_card("castling")
	check(castling != null, "castling card loads")
	if castling == null:
		return
	check(castling.rook_generated, "castling is flagged rook_generated")
	check(castling.card_type == CardData.CardType.SPELL, "castling is a spell")

	check_eq(CardData.get_card("rook").generated_card().id, "castling",
			"a plain Rook generates Castling")
	check_eq(CardData.get_card("rook_rook").generated_card().id, "castling",
			"the Turret (double rook) generates Castling")
	check_eq(CardData.get_card("pawn_rook").generated_card().id, "pawn_material",
			"composite rook buildings generate their authored delivery card (see test_materials)")

	check(not ("castling" in CardData.random_non_kings(99999)),
			"castling never surfaces in shop/reward pools")
	check(not Lab.is_mintable("castling"), "castling is not mintable in the Lab")

	# Casting grants Barrier to ONE manually-picked unit — not the whole board.
	var caster := CardInstance.from_data(castling)
	caster.owner = 0
	var a1 := unit("pawn")
	var a2 := unit("rook")
	var ctx := EffectContext.make(caster, [[a1, a2]], [[]])
	ctx.manual_target = a1
	var res: Array = []
	for e: Effect in castling.effects:
		if e.trigger == Effect.Trigger.ON_PLAY:
			res = EffectSystem.apply_single(e, caster, ctx)
	check(a1.find_status("barrier") != null, "castling grants Barrier to the picked unit")
	check(a2.find_status("barrier") == null, "the other ally is untouched (single target)")
	check(not res.is_empty(), "the grant produced a result (cue)")

	# A unit that already has a Barrier is not an eligible target: resolution refuses it
	# (condition), and the eligibility gate the targeting UI / enemy AI use says no.
	for e: Effect in castling.effects:
		if e.trigger == Effect.Trigger.ON_PLAY:
			res = EffectSystem.apply_single(e, caster, ctx)   # same target again
			check(not EffectSystem.passes_conditions(e.conditions, a1),
					"a Barriered unit fails the eligibility conditions")
			check(EffectSystem.passes_conditions(e.conditions, a2),
					"a Barrier-less unit passes the eligibility conditions")
	check(res.is_empty(), "re-casting at a Barriered unit resolves to nothing")
	var si := a1.find_status("barrier")
	check(si != null and si.stacks == 1, "no double-stack from the refused re-cast")

	# The condition round-trips through the authored schema.
	var cond := EffectCondition.from_dict({"status": "barrier", "present": false})
	var rt := EffectCondition.from_dict(cond.to_dict())
	check(rt.status_id == "barrier" and rt.present == false,
			"status condition round-trips (status/present)")

	# The protected read: Barrier declares the persistent aura (see CardUI._refresh_aura).
	check(StatusData.get_status("barrier").aura, "barrier declares the protected aura")
