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
	var a2 := unit("knight")
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
	# (The condition grammar is evaluated directly — the demolished eligibility helper's
	# verdicts must return through the rebuilt targeting authority.)
	for e: Effect in ab.effects:
		check(not _passes(e.conditions, a1),
				"a Barriered unit fails the eligibility conditions")
		check(_passes(e.conditions, a2),
				"a Barrier-less unit passes the eligibility conditions")
		res = EffectSystem.apply_single(e, holder, ctx)
	check(res.is_empty(), "re-casting at a Barriered unit resolves to nothing")
	check(si != null and si.stacks == 1, "no double-stack from the refused re-cast")

	# Rook exclusion: a unit carrying Rook in its composition can never be Castling's target,
	# Barrier or not — buildings don't get to hide behind Castling.
	var a3 := unit("rook")
	for e: Effect in ab.effects:
		check(not _passes(e.conditions, a3),
				"a unit with Rook in its composition fails eligibility, even without a Barrier")

	# The card-shaped tray view is presentational only.
	var display := ab.display_card()
	check(display.card_type == CardData.CardType.SPELL and display.cost == 1,
			"the display card mirrors the ability (spell-shaped, ability mana as cost)")
	check(not ("castling" in CardData.random_non_kings(99999)),
			"nothing castling-shaped exists in any card pool")

	# The protected read: Barrier declares the persistent aura (see CardUI._refresh_aura).
	check(StatusData.get_status("barrier").aura, "barrier declares the protected aura")

	_heal()


# The Bishop's Heal: 2 HP to a manually-picked unit, 1 mana + tap — pure authored content
# riding the ability system, zero engine code.
func _heal() -> void:
	var ab := AbilityData.get_ability("heal")
	check(ab != null, "heal ability definition loads")
	if ab == null:
		return
	check_eq(ab.mana, 1, "heal costs 1 mana")
	check(ab.tap, "heal taps its holder")
	check("heal" in CardData.get_card("bishop").ability_ids(), "the Bishop holds Heal")

	# CONTENT FORGOTTEN (effect-cleanse): heal's payload authors again in the new schema;
	# until then these are quarantined failures, not crashes.
	check(not ab.effects.is_empty(), "heal carries its authored effect")
	if ab.effects.is_empty():
		return
	var holder := unit("bishop")
	var t := unit("rook")
	Resolver.submit(StatMutation.make(t, StatMutation.HEALTH, -3, null))
	var ctx := EffectContext.make(holder, [[holder, t]], [[]])
	ctx.manual_target = t
	ctx.ability = ab
	var hp0 := t.current_health
	var res := EffectSystem.apply_single(ab.effects[0], holder, ctx)
	check_eq(t.current_health, hp0 + 2, "activation restores 2 HP to the picked unit")
	check(not res.is_empty(), "the heal produced a result (cue)")

	# At full HP the heal resolves to nothing (clamped by the Resolver, no phantom cue). The
	# pick-time gate can't yet EXCLUDE full units — "wounded" needs attribute-vs-attribute
	# condition vocabulary that doesn't exist; flagged as a known papercut.
	Resolver.fill_health(t)
	res = EffectSystem.apply_single(ab.effects[0], holder, ctx)
	check(res.is_empty(), "healing a full unit resolves to nothing")


# The demolished EffectSystem.passes_conditions helper, reproduced locally: the checks above
# pin the CONDITION GRAMMAR, which survives the targeting demolition.
func _passes(conds: Array, u: CardInstance) -> bool:
	for c: EffectCondition in conds:
		if not c.evaluate(u, -1):
			return false
	return true
