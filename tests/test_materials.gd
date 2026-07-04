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
	# Authored grants: each rook building declares `generates`; the delivery cards are REAL
	# JSON cards (rook_generated.json) — no synthesized effects for authored materials.
	var barracks := CardData.get_card("pawn_rook")
	var spell := barracks.generated_card()
	check(spell != null and spell.id == "pawn_material",
			"Barracks generates its AUTHORED delivery card (generates field)")
	if spell == null:
		return
	check(spell == CardData.get_card("pawn_material"),
			"the delivery card is the registered authored card, not a synthesized one")
	check(spell.card_type == CardData.CardType.SPELL, "material delivery is a spell")
	check(spell.rook_generated, "material spells are rook-generated (pool-excluded)")
	check(spell.elements.is_empty() and spell.chess_pieces.is_empty(),
			"the delivery card is its OWN card — no material composition on it")
	check_eq(spell.material, "pawn", "what it delivers is declared by the material field")
	check(spell.image != CardData.get_card("pawn").image,
			"the delivery card does not reuse the material's illustration")
	var fx: Array = spell.effects.filter(func(e: Effect) -> bool:
		return e.kind == Effect.Kind.CUSTOM and e.custom_id == "deliver_material" \
			and e.targeting_policy == Effect.TargetingPolicy.MANUAL_SLOT)
	check_eq(fx.size(), 1, "one MANUAL_SLOT deliver_material effect, authored in JSON")

	check_eq(CardData.get_card("knight_rook").generated_card().id, "knight_material",
			"Stable grants knight_material")
	check_eq(CardData.get_card("bishop_rook").generated_card().id, "bishop_material",
			"Arcane Tower grants bishop_material")
	check_eq(CardData.get_card("rook_queen").generated_card().id, "queen_material",
			"Castle grants queen_material")
	check_eq(CardData.get_card("darkness_water_rook").generated_card().id, "blight_material",
			"Blight Rook grants blight_material (element material, authored)")
	check_eq(CardData.get_card("rook").generated_card().id, "castling",
			"plain Rook grants Castling (authored via generates)")
	check_eq(CardData.get_card("rook_rook").generated_card().id, "castling",
			"Turret grants Castling")
	check(not ("pawn_material" in CardData.random_non_kings(99999)),
			"authored delivery cards never surface in shop/reward pools")

	# Un-authored combos (forge-derived rooks) fall back to a synthesized delivery card built
	# from the SAME authored schema (build_from_dict — no code-only effects).
	var derived := CardData.get_card("fire_rook")
	var fallback := derived.generated_card()
	check(fallback != null and fallback.id == "deliver_fire" and fallback.material == "fire",
			"un-authored rook combos fall back to a synthesized delivery card")
	check(fallback != null and derived.generated_card() == fallback,
			"fallback delivery cards are cached (stable identity)")

	# A "?"-event bump must not reset an authored grant: generates survives the override snapshot.
	var dc := DeckCard.make("pawn_rook")
	Resolver.submit(StatMutation.make(dc, StatMutation.ATTACK, 1, null, StatMutation.CH_SYSTEM))
	check_eq(dc.make_instance().data.generated_card().id, "pawn_material",
			"an upgraded (overridden) Barracks still grants pawn_material")


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
	check(not EffectSystem.passes_conditions(conds, unit("rook")),
			"rooks/buildings are never merge targets")
	check(not EffectSystem.passes_conditions(conds,
			CardInstance.from_data(CardData.get_card("pawn_rook"))),
			"composite buildings are never merge targets either")

	var espell := CardData.get_card("darkness_water_rook").generated_card()
	var econds: Array = (espell.effects[0] as Effect).conditions
	check(EffectSystem.passes_conditions(econds, unit("pawn")),
			"a no-element unit can take a 2-element material")
	check(not EffectSystem.passes_conditions(econds,
			CardInstance.from_data(CardData.get_card("fire_pawn"))),
			"1 existing element + 2 more would exceed the element cap")

	# Merge room is a plain COUNT query: composition sizes are ordinary condition attributes.
	check_eq(unit("pawn").get_attribute("piece_count"), 1, "piece_count queries the composition")
	check_eq(CardInstance.from_data(CardData.get_card("darkness_water")).get_attribute("element_count"), 2,
			"element_count queries the composition")
	var room := EffectCondition.from_dict(
			{"attribute": "piece_count", "comparator": "lte", "value": 1})
	check(room.evaluate(unit("pawn")), "a 1-piece unit has room for one more piece")
	check(not room.evaluate(CardInstance.from_data(CardData.get_card("pawn_pawn"))),
			"a 2-piece unit fails the count gate")


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
	var rook := unit("rook")
	ctx.manual_target = rook
	var rres := EffectSystem.apply_single(spell_inst.data.effects[0], spell_inst, ctx)
	check(rook.data.id == "rook" and rres.is_empty(),
			"the hook backstop refuses a rook merge outright")
