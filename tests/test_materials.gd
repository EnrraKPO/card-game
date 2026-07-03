extends TestCase

# Material delivery: composite rook buildings generate "Reinforce: X" spells whose composition
# IS the material — merged into an eligible own unit (composition combine, wounds carried) or
# spawned as a fresh unit on an empty own slot. See CardData._material_spell +
# EffectHooks.deliver_material. (The spawn half needs a live CombatBoard; covered by the enemy
# AI's spawn-equivalence and manual QA, not headless.)


func suite_name() -> String:
	return "Materials & merge"


func run() -> void:
	_generation()
	_eligibility()
	_merge()


func _generation() -> void:
	var barracks := CardData.get_card("pawn_rook")
	var spell := barracks.generated_card()
	check(spell != null and spell.id == "deliver_pawn", "Barracks generates the pawn material spell")
	if spell == null:
		return
	check(spell.card_type == CardData.CardType.SPELL, "material delivery is a spell")
	check(spell.rook_generated, "material spells are rook-generated (pool-excluded)")
	check(spell.chess_pieces.has("pawn") and spell.chess_pieces.size() == 1,
			"the spell carries the material as its own composition")
	check_eq(spell.cost, CardData.get_card("pawn").cost, "spell cost = the material card's cost")
	var fx: Array = spell.effects.filter(func(e: Effect) -> bool:
		return e.kind == Effect.Kind.CUSTOM and e.custom_id == "deliver_material" \
			and e.targeting_policy == Effect.TargetingPolicy.MANUAL_SLOT)
	check_eq(fx.size(), 1, "one MANUAL_SLOT deliver_material effect")
	check(barracks.generated_card() == spell, "material spells are cached (stable identity)")

	var espell := CardData.get_card("darkness_water_rook").generated_card()
	check(espell != null and espell.id == "deliver_darkness_water",
			"element-remainder rooks generate element material spells")
	check_eq(CardData.get_card("rook").generated_card().id, "castling",
			"plain Rook still generates Castling")
	check_eq(CardData.get_card("rook_rook").generated_card().id, "castling",
			"Turret still generates Castling")
	check(not ("deliver_pawn" in CardData.random_non_kings(99999)),
			"material spells never surface in shop/reward pools")


func _eligibility() -> void:
	var spell := CardData.get_card("pawn_rook").generated_card()
	var conds: Array = (spell.effects[0] as Effect).conditions
	check(EffectSystem.passes_conditions(conds, unit("pawn")),
			"a 1-piece unit can take a pawn material")
	check(not EffectSystem.passes_conditions(conds,
			CardInstance.from_data(CardData.get_card("pawn_pawn"))),
			"a 2-piece unit has no room for another piece")
	check(not EffectSystem.passes_conditions(conds, unit("king")),
			"kings are never merge targets (would lose is_king)")

	var espell := CardData.get_card("darkness_water_rook").generated_card()
	var econds: Array = (espell.effects[0] as Effect).conditions
	check(EffectSystem.passes_conditions(econds, unit("pawn")),
			"a no-element unit can take a 2-element material")
	check(not EffectSystem.passes_conditions(econds,
			CardInstance.from_data(CardData.get_card("fire_pawn"))),
			"1 existing element + 2 more would exceed the element cap")


func _merge() -> void:
	var spell_inst := CardInstance.from_data(CardData.get_card("pawn_rook").generated_card())
	spell_inst.owner = 0

	# A wounded, buffed, statused pawn: everything runtime must survive the merge.
	var t := unit("pawn")
	Resolver.submit(StatMutation.make(t, StatMutation.HEALTH, -2, null))
	Resolver.submit(StatMutation.make(t, StatMutation.ATTACK, 1, null))
	t.apply_status("empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	var ctx := EffectContext.make(spell_inst, [[t]], [[]])
	ctx.manual_target = t
	var res := EffectSystem.apply_single(spell_inst.data.effects[0], spell_inst, ctx)
	check_eq(t.data.id, "pawn_pawn", "merge combines the compositions (pawn + pawn material)")
	check(not res.is_empty(), "merge produced a result (cue)")
	check_eq(t.current_health, t.get_attribute("max_health") - 2,
			"wounds carry over as a damage delta — merging never heals")
	var combined := CardData.combine(CardData.get_card("pawn"), CardData.get_card("pawn"))
	check_eq(t.get_attribute("attack"), combined.attack + 1 + 2,
			"runtime modifiers and status bonuses keep folding after the merge")
	check(t.find_status("empowered") != null, "statuses survive the merge")

	# Never lethal, and the hook's king backstop holds even if conditions were bypassed.
	var t2 := unit("pawn")
	Resolver.set_health(t2, 1)
	ctx.manual_target = t2
	EffectSystem.apply_single(spell_inst.data.effects[0], spell_inst, ctx)
	check(t2.current_health >= 1 and t2.data.id == "pawn_pawn",
			"a 1-HP unit survives its merge")
	var king := unit("king")
	ctx.manual_target = king
	var kres := EffectSystem.apply_single(spell_inst.data.effects[0], spell_inst, ctx)
	check(king.data.is_king and kres.is_empty(),
			"the hook backstop refuses a king merge outright")
