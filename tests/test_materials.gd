extends TestCase

# Material delivery as ACTIVATED ABILITIES: buildings hold "X Material" abilities (AbilityData,
# `material` field names what's delivered), activation merges the material into an own unit
# (composition combine, wounds carried) or spawns it on an empty own slot. See
# EffectHooks.deliver_material. (The spawn half needs a live CombatBoard; covered by the enemy
# AI's spawn path and manual QA, not headless.)


func suite_name() -> String:
	return "Materials & merge"


func run() -> void:
	_definitions()
	_holders()
	_eligibility()
	_merge()


func _definitions() -> void:
	var ab := AbilityData.get_ability("pawn_material")
	check(ab != null, "pawn_material ability definition loads")
	if ab == null:
		return
	check_eq(ab.material, "pawn", "what it delivers is declared by the material field")
	check(ab.tap, "material delivery taps the holder")
	# TARGETING REMOVED (targeting-cleanup demolition): the authored manual_slot policy is
	# opaque data now — the classification half of this check returns with the authority.
	var fx: Array = ab.effects.filter(func(e: Effect) -> bool:
		return e.kind == Effect.Kind.CUSTOM and e.custom_id == "deliver_material")
	check_eq(fx.size(), 1, "one deliver_material effect, authored in JSON")
	check(CardData.get_card("pawn_material") == null, "material abilities are not cards")


func _holders() -> void:
	check("pawn_material" in CardData.get_card("pawn_rook").ability_ids(),
			"Barracks holds pawn_material")
	check("knight_material" in CardData.get_card("knight_rook").ability_ids(),
			"Stable holds knight_material")
	check("bishop_material" in CardData.get_card("bishop_rook").ability_ids(),
			"Arcane Tower holds bishop_material")
	check("queen_material" in CardData.get_card("rook_queen").ability_ids(),
			"Castle holds queen_material")
	check("blight_material" in CardData.get_card("darkness_water_rook").ability_ids(),
			"Blight Rook holds blight_material")

	# Instance-level resolution: base + status-held, at read time — abilities are transient.
	var inst := unit("rook")
	var names: Array = inst.ability_list().map(func(a: AbilityData) -> String: return a.id)
	check("castling" in names, "an instance resolves its card's held abilities")
	StatusData._all["_t_ability_grant"] = StatusData.from_dict(
			{"id": "_t_ability_grant", "abilities": ["pawn_material"], "decay": "none"})
	StatusEngine.apply(inst, "_t_ability_grant", Effect.STATUS_DURATION_DEFAULT, 1, null)
	names = inst.ability_list().map(func(a: AbilityData) -> String: return a.id)
	check("pawn_material" in names, "a status-held ability is ported to the carrier")
	inst.remove_status("_t_ability_grant")
	names = inst.ability_list().map(func(a: AbilityData) -> String: return a.id)
	check(not ("pawn_material" in names), "and leaves with the status (transient by nature)")

	# Rook combos with no authored abilities synthesize a fallback ability from the same
	# authored schema; authoring the id in data/abilities/ would replace it. (fire_rook
	# itself gained an authored ability in the unit data pass, so the fixture is the
	# still-unauthored Fire Turret — same "fire" remainder.)
	var derived := CardData.get_card("fire_rook_rook")
	var ids := derived.ability_ids()
	check(ids.size() == 1 and str(ids[0]) == "deliver_fire",
			"derived rook combos fall back to a synthesized material ability")
	var fb := AbilityData.get_ability("deliver_fire")
	check(fb != null and fb.material == "fire", "the fallback delivers its remainder")
	check(AbilityData.get_ability("deliver_fire") == fb, "the fallback is cached (stable identity)")

	# A "?"-event bump must not reset a rook's held abilities: they round-trip the override.
	var dc := DeckCard.make("pawn_rook")
	Resolver.submit(StatMutation.make(dc, StatMutation.ATTACK, 1, null, StatMutation.CH_SYSTEM))
	check("pawn_material" in dc.make_instance().data.ability_ids(),
			"an upgraded (overridden) Barracks still holds pawn_material")


# The demolished EffectSystem.passes_conditions helper, reproduced locally: these cases pin
# the CONDITION GRAMMAR (which survives — EffectCondition), not targeting. The rebuilt
# targeting authority's eligibility must give the same verdicts through its own front door.
func _passes(conds: Array, u: CardInstance) -> bool:
	for c: EffectCondition in conds:
		if not c.evaluate(u, -1):
			return false
	return true


func _eligibility() -> void:
	var ab := AbilityData.get_ability("pawn_material")
	# CONTENT FORGOTTEN (effect-cleanse): the material payloads author again in the new
	# schema; until then these are quarantined failures, not crashes.
	check(not ab.effects.is_empty(), "pawn_material carries its authored effect")
	if ab.effects.is_empty():
		return
	var conds: Array = (ab.effects[0] as Effect).conditions
	check(_passes(conds, unit("pawn")),
			"a 1-piece unit can take a pawn material")
	check(not _passes(conds,
			CardInstance.from_data(CardData.get_card("pawn_pawn"))),
			"a 2-piece unit has no room for another piece")
	check(not _passes(conds, unit("king")),
			"kings are never merge targets")
	check(not _passes(conds, unit("rook")),
			"rooks/buildings are never merge targets")

	var econds: Array = (AbilityData.get_ability("blight_material").effects[0] as Effect).conditions
	check(_passes(econds, unit("pawn")),
			"a no-element unit can take a 2-element material")
	check(not _passes(econds,
			CardInstance.from_data(CardData.get_card("fire_pawn"))),
			"an element-carrying unit exceeds the element cap")

	# The composition counts stay ordinary queryable attributes.
	check_eq(unit("pawn").get_attribute("piece_count"), 1, "piece_count queries the composition")
	check_eq(CardInstance.from_data(CardData.get_card("darkness_water")).get_attribute("element_count"), 2,
			"element_count queries the composition")


func _merge() -> void:
	var ab := AbilityData.get_ability("pawn_material")
	check(not ab.effects.is_empty(), "pawn_material carries its merge effect")
	if ab.effects.is_empty():
		return
	var holder := unit("rook")   # an ability acts AS its holder

	# A wounded, buffed, statused pawn: everything runtime must survive the merge.
	var t := unit("pawn")
	Resolver.submit(StatMutation.make(t, StatMutation.HEALTH, -2, null))
	Resolver.submit(StatMutation.make(t, StatMutation.ATTACK, 1, null))
	StatusEngine.apply(t, "empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	var ctx := EffectContext.make(holder, [[holder, t]], [[]])
	ctx.manual_target = t
	ctx.ability = ab
	var res := EffectSystem.apply_single(ab.effects[0], holder, ctx)
	check_eq(t.data.id, "pawn_pawn", "merge combines the compositions (pawn + pawn material)")
	check(not res.is_empty(), "merge produced a result (cue)")
	check_eq(t.current_health, t.get_attribute("max_health") - 2,
			"wounds carry over as a damage delta — merging never heals")
	var combined := CardData.combine(CardData.get_card("pawn"), CardData.get_card("pawn"))
	check_eq(t.get_attribute("attack"), combined.attack + 1 + 2,
			"runtime modifiers and status bonuses keep folding after the merge")
	check(t.find_status("empowered") != null, "statuses survive the merge")

	# Never lethal; king/rook backstops; a context without an ability is a silent no-op.
	var t2 := unit("pawn")
	Resolver.set_health(t2, 1)
	ctx.manual_target = t2
	EffectSystem.apply_single(ab.effects[0], holder, ctx)
	check(t2.current_health >= 1 and t2.data.id == "pawn_pawn", "a 1-HP unit survives its merge")
	var king := unit("king")
	ctx.manual_target = king
	var kres := EffectSystem.apply_single(ab.effects[0], holder, ctx)
	check(king.data.is_king and kres.is_empty(), "the hook backstop refuses a king merge outright")
	var rook := unit("rook")
	ctx.manual_target = rook
	var rres := EffectSystem.apply_single(ab.effects[0], holder, ctx)
	check(rook.data.id == "rook" and rres.is_empty(), "the hook backstop refuses a rook merge outright")
	ctx.ability = null
	ctx.manual_target = unit("pawn")
	check(EffectSystem.apply_single(ab.effects[0], holder, ctx).is_empty(),
			"no ability on the context -> silent no-op")
