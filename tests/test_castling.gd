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
	check_eq(CardData.get_card("pawn_rook").generated_card().id, "pawn",
			"composite rook buildings still generate their non-rook piece")

	check(not ("castling" in CardData.random_non_kings(99999)),
			"castling never surfaces in shop/reward pools")
	check(not Lab.is_mintable("castling"), "castling is not mintable in the Lab")

	# Casting grants Barrier to every ally.
	var caster := CardInstance.from_data(castling)
	caster.owner = 0
	var a1 := unit("pawn")
	var a2 := unit("rook")
	var ctx := EffectContext.make(caster, [[a1, a2]], [[]])
	for e: Effect in castling.effects:
		if e.trigger == Effect.Trigger.ON_PLAY:
			EffectSystem.apply_single(e, caster, ctx)
	check(a1.find_status("barrier") != null and a2.find_status("barrier") != null,
			"castling grants Barrier to every ally")

	# The protected read: Barrier declares the persistent aura (see CardUI._refresh_aura).
	check(StatusData.get_status("barrier").aura, "barrier declares the protected aura")
