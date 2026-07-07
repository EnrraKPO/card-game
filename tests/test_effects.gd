extends TestCase

# The effect pipeline riding the Resolver: the three stat-write paths behave exactly as they
# did pre-Resolver (heal clamp + landed-delta results, shield-first damage_taken, modifiers),
# plus interception inside the gate (block/armor forms, channel policy, clamping, cue records).


func suite_name() -> String:
	return "Effects & Interception"


func run() -> void:
	_effect_write_paths()
	_interception()
	_channel_policy()
	_interceptor_round_trip()
	_composition_conditions()
	_conditioned_modifiers()
	_run_scope_allegiance()


# Modifier targeting is gated by `conditions` exactly like triggered targeting: every card the
# modifier would fold into is a TARGET, tested with the full EffectCondition vocabulary
# (composition / stat / status forms). The legacy `filter` keeps working alongside.
func _conditioned_modifiers() -> void:
	var pawn := unit("pawn")
	var knight := unit("knight")
	var base_pawn_hp := pawn.get_attribute("max_health")
	var base_knight_hp := knight.get_attribute("max_health")

	# Run-wide "+1 health to pawn units" — composition-form condition on a card modifier.
	var pawn_buff := Effect.from_dict({"kind": "modifier", "key": "unit.health", "amount": 1,
			"conditions": [{"composition": ["pawn"]}]})
	GameData.current_modifiers.add(pawn_buff)
	check_eq(pawn.get_attribute("max_health"), base_pawn_hp + 1,
			"conditioned modifier reaches a pawn (+1 health)")
	check_eq(knight.get_attribute("max_health"), base_knight_hp,
			"conditioned modifier skips a knight")

	# Stat-form condition on a DIFFERENT attribute than the one modified.
	var frail_buff := Effect.from_dict({"kind": "modifier", "key": "unit.attack", "amount": 2,
			"conditions": [{"attribute": "health", "comparator": "lte",
				"value": pawn.get_attribute("max_health")}]})
	GameData.current_modifiers.add(frail_buff)
	var base_pawn_atk := unit("pawn").data.attack
	check_eq(unit("pawn").get_attribute("attack"), base_pawn_atk + 2,
			"stat-form condition gates a modifier (pawn is frail enough)")

	# Self-referential guard: a modifier conditioned on the attribute it feeds must terminate,
	# and the condition sees the unit valued WITHOUT condition-bearing modifiers.
	var self_ref := Effect.from_dict({"kind": "modifier", "key": "unit.attack", "amount": 1,
			"conditions": [{"attribute": "attack", "comparator": "gte", "value": 0}]})
	GameData.current_modifiers.add(self_ref)
	check_eq(unit("pawn").get_attribute("attack"), base_pawn_atk + 2 + 1,
			"self-referential modifier condition terminates and applies")

	GameData.current_modifiers = ModifierSet.new()   # restore the clean env

	# Status-held card modifiers gate on the carrier the same way.
	var picky := StatusData.from_dict({"id": "_test_picky", "effects": [
			{"kind": "modifier", "key": "unit.attack", "amount": 3,
				"conditions": [{"composition": ["pawn"]}]}]})
	var carrier_pawn := unit("pawn")
	carrier_pawn.statuses.append(StatusInstance.make(picky, 2, 1, null))
	var carrier_knight := unit("knight")
	carrier_knight.statuses.append(StatusInstance.make(picky, 2, 1, null))
	check_eq(carrier_pawn.get_attribute("attack"), carrier_pawn.data.attack + 3,
			"status-held conditioned modifier buffs a matching carrier")
	check_eq(carrier_knight.get_attribute("attack"), carrier_knight.data.attack,
			"status-held conditioned modifier skips a non-matching carrier")

	# Authored round-trip: conditions survive modifier serialization.
	var rt := Effect.from_dict(pawn_buff.to_dict())
	check(rt.kind == Effect.Kind.MODIFIER and rt.conditions.size() == 1
			and (rt.conditions[0] as EffectCondition).composition == ["pawn"],
			"modifier conditions round-trip through to_dict/from_dict")


# ALLEGIANCE in a HOLDERLESS container — the capability the owner model unlocks: a native
# run-scope standing effect says "your units" as data ({"allegiance": "ally"}), no unit
# holder anywhere. The run container is owned by the player, so ally = player units only.
func _run_scope_allegiance() -> void:
	var mine := unit("pawn")            # owner 0 (player)
	var foe := unit("pawn")
	foe.owner = 1
	var neutral := unit("pawn")
	neutral.owner = -1                  # non-combat (preview) instance
	GameData.current_modifiers.add(Effect.from_dict({
			"trigger": {"kind": "while"},
			"targets": {"kind": "all", "conditions": [{"allegiance": "ally"}]},
			"attribute": "attack", "amount": 2}))
	check_eq(mine.get_attribute("attack"), mine.data.attack + 2,
			"run-scope ally standing effect reaches a player unit")
	check_eq(foe.get_attribute("attack"), foe.data.attack,
			"…and never an enemy unit")
	check_eq(neutral.get_attribute("attack"), neutral.data.attack,
			"…and never a sideless (preview) instance")
	GameData.current_modifiers = ModifierSet.new()   # restore the clean env


func _composition_conditions() -> void:
	# The "lackeys only" gate: composition must contain neither king nor queen.
	var lackeys_only := EffectCondition.from_dict({"composition": ["king", "queen"], "present": false})
	check(lackeys_only.evaluate(unit("pawn")), "a pawn passes the lackeys-only gate")
	check(lackeys_only.evaluate(unit("rook")), "a rook passes the lackeys-only gate")
	check(not lackeys_only.evaluate(unit("king")), "the King (composition contains king) fails it")
	check(not lackeys_only.evaluate(unit("queen")), "the Queen fails it")
	check(not lackeys_only.evaluate(unit("rook_queen")), "the Castle (rook+queen combo) fails it")

	# present: true = "contains any of these" — the element-gate form (Blinding Ward's twin).
	var light_only := EffectCondition.from_dict({"composition": "light"})
	var light_unit := CardInstance.from_data(CardData.get_card("light_pawn"))
	if light_unit == null or light_unit.data == null:
		light_unit = CardInstance.from_data(CardData.get_card("light"))
	check(light_only.evaluate(light_unit), "a light-composed card passes the light gate")
	check(not light_only.evaluate(unit("pawn")), "a plain pawn fails the light gate")

	# Round-trips through the authored schema, list normalized.
	var rt := EffectCondition.from_dict(lackeys_only.to_dict())
	check(rt.composition == ["king", "queen"] and rt.present == false,
			"composition condition round-trips (list + present)")


# A throwaway unit whose CARD carries the given interceptor effects (native interceptors are
# unscaled; status-carried ones are exercised in the statuses suite via Blind).
func _interceptor_unit(fx: Array) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_interceptor", "display_name": "T",
		"cost": 1, "attack": 2, "health": 9, "speed": 1, "shield": 3,
		"effects": fx,
	}))
	inst.owner = 0
	return inst


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


func _interception() -> void:
	# SOURCE role: a blocker's own strike is multiplied to nothing inside the gate.
	var blocker := _interceptor_unit([
		{"intercept": "damage", "channel": "attack", "role": "source", "op": "mul", "amount": 0},
	])
	var victim := unit("rook")
	var hp0 := victim.current_health
	var out := Resolver.submit(StatMutation.damage(victim, 5, blocker))
	check_eq(out.delta, 0, "source-role mul-0 blocks the strike inside the gate (5 -> 0)")
	check_eq(victim.current_health, hp0, "blocked strike leaves the target unwounded")
	check_eq(victim.current_shield, 3, "blocked strike leaves the shield untouched")
	check_eq(out.interceptions.size(), 1, "outcome records the interception (for the cue)")
	check_eq(int(out.interceptions[0].get("delta", 1)), -5, "interception record carries its delta")

	# A LATER strike from a clean source is untouched — nothing persists anywhere.
	var clean := unit("pawn")
	var later := Resolver.submit(StatMutation.damage(victim, 3, clean))
	check_eq(later.delta, -3, "a later strike carries no residue from the blocked one")

	# TARGET role: armor on the defender shaves the hit before the shield sees it.
	var armored := _interceptor_unit([
		{"intercept": "damage", "channel": "attack", "role": "target", "amount": -3},
	])
	var hit := Resolver.submit(StatMutation.damage(armored, 5, clean))
	check_eq(hit.shield_absorbed, 2, "armor -3 shaves 5 -> 2 before shield resolution")
	check_eq(armored.current_health, 9, "armored unit's health untouched (shield held)")
	var over := Resolver.submit(StatMutation.damage(armored, 2, clean))
	check_eq(over.delta, 0, "over-armor clamps at 0 — never flips into a heal")

	# Roles don't cross: a source-role interceptor never fires when its holder is the TARGET.
	var on_holder := Resolver.submit(StatMutation.damage(blocker, 4, clean))
	check_eq(on_holder.delta, -4, "source-role interceptor ignores hits ON its holder (full 4 lands)")
	check(on_holder.interceptions.is_empty(), "no interception recorded for the wrong role")

	# chance: 0.0 never fires.
	var lucky := _interceptor_unit([
		{"intercept": "damage", "channel": "attack", "role": "target", "op": "mul", "amount": 0, "chance": 0.0},
	])
	var through := Resolver.submit(StatMutation.damage(lucky, 4, clean))
	check_eq(through.delta, -4, "chance-0 interceptor never fires")
	check(through.interceptions.is_empty(), "a non-firing interceptor records nothing")


func _channel_policy() -> void:
	# An attack-only barrier ignores everything that isn't attack-channel damage.
	var barrier := _interceptor_unit([
		{"intercept": "damage", "channel": "attack", "role": "target", "op": "mul", "amount": 0},
	])
	var hp0 := barrier.current_health

	# A poison-style direct HEALTH change: different stat entirely — sails through.
	Resolver.submit(StatMutation.make(barrier, StatMutation.HEALTH, -2, null))
	check_eq(barrier.current_health, hp0 - 2, "direct health change ignores a damage barrier")

	# Spell/effect damage (damage_taken path submits on the EFFECT channel): same stat,
	# different channel — sails through too. This pins the channel policy.
	var dmg_eff := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "damage_taken", "amount": 4})
	EffectSystem.apply_single(dmg_eff, barrier, ctx_for(barrier))
	check_eq(barrier.current_shield, 0, "effect-channel damage passes an attack-only barrier (shield eats 3)")
	check_eq(barrier.current_health, hp0 - 2 - 1, "effect-channel damage bleeds through normally")

	# Attack-channel damage IS blocked.
	var blocked := Resolver.submit(StatMutation.damage(barrier, 5, unit("pawn")))
	check_eq(blocked.delta, 0, "attack-channel damage is blocked by the barrier")


func _interceptor_round_trip() -> void:
	var e := Effect.from_dict({"intercept": "damage", "channel": "attack", "role": "source",
			"op": "mul", "amount": 0, "chance": 0.5})
	check(e.kind == Effect.Kind.INTERCEPTOR, "'intercept' key infers the INTERCEPTOR kind")
	var rt := Effect.from_dict(e.to_dict())
	check(rt.kind == Effect.Kind.INTERCEPTOR and rt.intercept == StatMutation.DAMAGE
			and rt.channel == StatMutation.CH_ATTACK and rt.role == Effect.Role.SOURCE
			and rt.op == Effect.Op.MUL and rt.chance == 0.5,
			"interceptor round-trips intact (stat/channel/role/op/chance)")
