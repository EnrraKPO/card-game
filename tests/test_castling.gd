extends TestCase

# Castling as an ACTIVATED ABILITY (see AbilityData): rook buildings hold it; activation
# grants a Barrier to one manually-picked unit that has none — sourced from the HOLDER.


func suite_name() -> String:
	return "Castling & abilities"


func run() -> void:
	var ab := AbilityData.get_ability("castling")
	check(ab != null, "castling ability definition loads")
	if ab == null:
		return
	check_eq(ab.mana, 1, "castling costs 1 mana")
	check(ab.tap, "castling taps its holder")
	check(CardData.get_card("castling") == null,
			"castling is not a card — no pool-exclusion story needed at all")
	check("castling" in CardData.get_card("rook").ability_ids(), "the Rook holds Castling")
	check("castling" in CardData.get_card("rook_rook").ability_ids(), "the Turret holds Castling")

	# Activation grants Barrier to ONE picked unit; the effects' source is the HOLDER.
	var holder := unit("rook")
	var a1 := unit("pawn")
	var a2 := unit("rook")
	var ctx := EffectContext.make(holder, [[a1, a2]], [[]])
	ctx.manual_target = a1
	ctx.ability = ab
	var res: Array = []
	for e: Effect in ab.effects:
		res = EffectSystem.apply_single(e, holder, ctx)
	check(a1.find_status("barrier") != null, "activation grants Barrier to the picked unit")
	check(a2.find_status("barrier") == null, "the other ally is untouched (single target)")
	check(not res.is_empty(), "the grant produced a result (cue)")
	var si := a1.find_status("barrier")
	check(si != null and si.source == holder, "the Barrier's source is the HOLDER (the rook)")

	# Eligibility: Barriered units are not valid picks; a refused re-cast does nothing.
	for e: Effect in ab.effects:
		check(not EffectSystem.passes_conditions(e.conditions, a1),
				"a Barriered unit fails the eligibility conditions")
		check(EffectSystem.passes_conditions(e.conditions, a2),
				"a Barrier-less unit passes the eligibility conditions")
		res = EffectSystem.apply_single(e, holder, ctx)
	check(res.is_empty(), "re-casting at a Barriered unit resolves to nothing")
	check(si != null and si.stacks == 1, "no double-stack from the refused re-cast")

	# The card-shaped tray view is presentational only.
	var display := ab.display_card()
	check(display.card_type == CardData.CardType.SPELL and display.cost == 1,
			"the display card mirrors the ability (spell-shaped, ability mana as cost)")
	check(not ("castling" in CardData.random_non_kings(99999)),
			"nothing castling-shaped exists in any card pool")

	# The protected read: Barrier declares the persistent aura (see CardUI._refresh_aura).
	check(StatusData.get_status("barrier").aura, "barrier declares the protected aura")
