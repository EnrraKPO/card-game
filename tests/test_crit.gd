extends TestCase

# The core CRIT rule (Resolver): an attack strike can land as a CRITICAL, multiplying the
# post-interception damage. The chance is DATA-DRIVEN (data/combat_tuning.json "crit" →
# Resolver.crit_chance), driven by the ATTACKER's speed (the offensive mirror of dodge —
# Speed is the precision stat on both sides of an exchange):
#     fixed_pct + per_speed_pct × attacker_speed + per_speed_diff_pct × max(0, atk − tgt speed)
# capped at max_pct. The damage factor is Resolver.crit_multiplier (tuning base + the attacker's
# crit_multiplier_bonus in points ×100, capped at multiplier_max). Crit resolves AFTER
# interception — it only rolls on a hit that still deals > 0 — and reports Outcome.crit +
# crit_bonus_damage. Core combat, not an effect — proven here rather than in the effect suites.
#
# Same two halves as the dodge suite: the CHANCE/MULTIPLIER FORMULAS are pure functions (no RNG),
# and the ROLL is exercised only at the certain (100%) and impossible (0%) ends.

const EPS := 0.0005


func suite_name() -> String:
	return "Crit"


func run() -> void:
	_chance_formula()
	_multiplier_formula()
	_crit_chance_bonus_fold()
	_crit_multiplier_bonus_fold()
	var prev := Resolver.crit_enabled
	Resolver.crit_enabled = true
	_certain_crit_multiplies_damage()
	_impossible_crit_lands_base()
	_crit_is_attack_channel_only()
	_toggle_off_never_crits()
	Resolver.crit_enabled = prev
	Resolver.set_crit_tuning({})   # drop the injected cache; later reads reload from disk


# The pure chance function against injected tuning. NOTE the participant order relative to
# dodge_chance: crit_chance(ATTACKER, target) — the first argument owns the quantity.
func _chance_formula() -> void:
	Resolver.set_crit_tuning({
		"fixed_pct": 0.0, "per_speed_pct": 1.0, "per_speed_diff_pct": 4.0, "max_pct": 75.0,
	})
	_near(Resolver.crit_chance(_spd(5)), 0.05, "per-speed only: 1% × attacker speed 5 = 5%")
	_near(Resolver.crit_chance(_spd(6), _spd(2)), 0.22,
			"faster attacker: 1%×6 + 4%×(6−2) = 6% + 16% = 22%")
	_near(Resolver.crit_chance(_spd(2), _spd(6)), 0.02,
			"slower attacker: edge term is one-sided — just the 2% per-speed, no penalty")
	_near(Resolver.crit_chance(_spd(4), _spd(4)), 0.04,
			"equal speed: no edge bonus, just 4% per-speed")
	check_eq(Resolver.crit_chance(null), 0.0, "a null attacker has no crit chance")

	# Fixed base stacks on top of the per-speed term.
	Resolver.set_crit_tuning({"fixed_pct": 10.0, "per_speed_pct": 1.0})
	_near(Resolver.crit_chance(_spd(3)), 0.13, "fixed 10% + 1%×speed 3 = 13%")

	# The cap ceils the total, however large the terms get.
	Resolver.set_crit_tuning({"per_speed_pct": 1.0, "per_speed_diff_pct": 4.0, "max_pct": 20.0})
	_near(Resolver.crit_chance(_spd(6), _spd(0)), 0.20,
			"raw 6% + 24% = 30% is capped to the 20% ceiling")

	# Buildings are NOT excluded (settled design, unlike dodge): a rook attacker crits normally.
	Resolver.set_crit_tuning({"fixed_pct": 30.0, "per_speed_pct": 0.0, "per_speed_diff_pct": 0.0})
	_near(Resolver.crit_chance(_building()), 0.30, "a building attacker has a normal crit chance")


# The pure multiplier function: tuning base + the attacker's crit_multiplier_bonus (points ×100),
# capped at multiplier_max and floored at 1.0.
func _multiplier_formula() -> void:
	Resolver.set_crit_tuning({"multiplier": 2.0, "multiplier_max": 5.0})
	var u := _unit(3, 9, 0)
	_near(Resolver.crit_multiplier(u), 2.0, "base multiplier straight from tuning")
	Resolver.submit(StatMutation.make(u, StatMutation.CRIT_MULTIPLIER_BONUS, 50, null, StatMutation.CH_SYSTEM))
	check_eq(u.get_attribute("crit_multiplier_bonus"), 50, "a crit_multiplier_bonus modifier folds into get_attribute")
	_near(Resolver.crit_multiplier(u), 2.5, "a +50-point bonus lifts a 2.0 base to 2.5×")

	# The ceiling bounds the bonus — no relic makes a hit infinite.
	Resolver.set_crit_tuning({"multiplier": 2.0, "multiplier_max": 2.2})
	_near(Resolver.crit_multiplier(u), 2.2, "multiplier_max caps a bonus that would exceed it")

	# The floor: a multiplier can never dip below 1.0 (a crit never deals LESS than the base hit).
	Resolver.set_crit_tuning({"multiplier": 0.5, "multiplier_max": 5.0})
	_near(Resolver.crit_multiplier(_unit(3, 9, 0)), 1.0, "the multiplier floors at 1.0")


# The `crit_chance_bonus` stat: extra crit percentage points, foldable by standing effects. A
# written modifier and a run-level standing modifier (the Eagle-Eye Charm relic) both flow into
# crit_chance — the attacker-side mirror of _dodge_bonus_fold.
func _crit_chance_bonus_fold() -> void:
	# Zero out the speed-derived terms so the bonus is the whole chance.
	Resolver.set_crit_tuning({"fixed_pct": 0.0, "per_speed_pct": 0.0, "per_speed_diff_pct": 0.0, "max_pct": 100.0})
	var u := _unit(5, 9, 0)
	_near(Resolver.crit_chance(u), 0.0, "no bonus, zero rates → 0% crit")
	Resolver.submit(StatMutation.make(u, StatMutation.CRIT_CHANCE_BONUS, 25, null, StatMutation.CH_SYSTEM))
	check_eq(u.get_attribute("crit_chance_bonus"), 25, "a crit_chance_bonus modifier folds into get_attribute")
	_near(Resolver.crit_chance(u), 0.25, "a +25 crit_chance_bonus adds 25% to the chance")

	# The cap bounds the bonus too — no attacker crits every time past the ceiling.
	Resolver.set_crit_tuning({"fixed_pct": 0.0, "per_speed_pct": 0.0, "max_pct": 20.0})
	_near(Resolver.crit_chance(u), 0.20, "the cap ceils a bonus that would exceed it")

	# The Eagle-Eye Charm relic: a run-level standing modifier granting +25 crit_chance_bonus to
	# allied AIR units only — anchored to the player, gated by composition.
	Resolver.set_crit_tuning({"fixed_pct": 0.0, "per_speed_pct": 0.0, "per_speed_diff_pct": 0.0, "max_pct": 100.0})
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_modifiers.add(Effect.from_dict({
		"kind": "modifier", "key": "unit.crit_chance_bonus", "amount": 25,
		"conditions": [{"composition": ["air"]}],
	}))
	var air_ally := _unit(5, 9, 0, ["air"], 0)
	var fire_ally := _unit(5, 9, 0, ["fire"], 0)
	var air_enemy := _unit(5, 9, 0, ["air"], 1)
	check_eq(air_ally.get_attribute("crit_chance_bonus"), 25, "the relic grants +25 crit chance to an allied air unit")
	check_eq(fire_ally.get_attribute("crit_chance_bonus"), 0, "a non-air ally gets no crit-chance bonus")
	check_eq(air_enemy.get_attribute("crit_chance_bonus"), 0, "an enemy air unit gets no player-scoped bonus")
	_near(Resolver.crit_chance(air_ally), 0.25, "the granted bonus flows into the air unit's crit chance")
	GameData.current_modifiers = ModifierSet.new()


# The `crit_multiplier_bonus` stat — the axis dodge never had: extra multiplier points ×100,
# foldable by standing effects (the Executioner's Edge relic) into crit_multiplier.
func _crit_multiplier_bonus_fold() -> void:
	Resolver.set_crit_tuning({"multiplier": 2.0, "multiplier_max": 5.0})
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_modifiers.add(Effect.from_dict({
		"kind": "modifier", "key": "unit.crit_multiplier_bonus", "amount": 50,
		"conditions": [{"composition": ["darkness"]}],
	}))
	var dark_ally := _unit(5, 9, 0, ["darkness"], 0)
	var fire_ally := _unit(5, 9, 0, ["fire"], 0)
	var dark_enemy := _unit(5, 9, 0, ["darkness"], 1)
	check_eq(dark_ally.get_attribute("crit_multiplier_bonus"), 50, "the relic grants +50 multiplier points to an allied darkness unit")
	check_eq(fire_ally.get_attribute("crit_multiplier_bonus"), 0, "a non-darkness ally gets no multiplier bonus")
	check_eq(dark_enemy.get_attribute("crit_multiplier_bonus"), 0, "an enemy darkness unit gets no player-scoped bonus")
	_near(Resolver.crit_multiplier(dark_ally), 2.5, "the granted bonus lifts the darkness unit's crits to 2.5×")
	_near(Resolver.crit_multiplier(fire_ally), 2.0, "a non-darkness ally keeps the base multiplier")

	# multiplier_max caps the relic-boosted factor too.
	Resolver.set_crit_tuning({"multiplier": 2.0, "multiplier_max": 2.2})
	_near(Resolver.crit_multiplier(dark_ally), 2.2, "multiplier_max caps the relic-boosted factor")
	GameData.current_modifiers = ModifierSet.new()


# At a certain (100%, uncapped) chance the strike lands multiplied, and the outcome reports the
# crit + the exact bonus.
func _certain_crit_multiplies_damage() -> void:
	Resolver.set_crit_tuning({"fixed_pct": 100.0, "per_speed_pct": 0.0, "per_speed_diff_pct": 0.0,
			"max_pct": 100.0, "multiplier": 2.0, "multiplier_max": 5.0})
	var tgt := _unit(0, 12, 0)
	var out := Resolver.submit(StatMutation.damage(tgt, 4, _unit(1, 5, 0)))
	check(out.crit, "a certain-crit strike flags the outcome as a crit")
	check_eq(out.crit_bonus_damage, 4, "a 2.0× crit on a 4 hit adds exactly 4 bonus damage")
	check_eq(out.delta, -8, "the strike lands multiplied (4 × 2.0 = 8)")
	check_eq(tgt.current_health, 4, "the target is wounded by the full crit amount")

	# A sourceless hit can never crit — there is no attacker to own the chance.
	var tgt2 := _unit(0, 12, 0)
	var out2 := Resolver.submit(StatMutation.damage(tgt2, 4, null))
	check(not out2.crit, "a sourceless strike never crits, whatever the tuning")
	check_eq(out2.delta, -4, "the sourceless strike lands at base damage")


# At a 0% chance the strike always resolves at its base amount.
func _impossible_crit_lands_base() -> void:
	Resolver.set_crit_tuning({"fixed_pct": 0.0, "per_speed_pct": 0.0, "per_speed_diff_pct": 0.0})
	var tgt := _unit(0, 9, 0)
	var out := Resolver.submit(StatMutation.damage(tgt, 4, _spd(9)))
	check(not out.crit, "a 0%-tuning attacker never crits, however fast")
	check_eq(out.crit_bonus_damage, 0, "no bonus damage without a crit")
	check_eq(out.delta, -4, "the strike lands at base damage")


# Crit is attack-channel only: a poison-form HEALTH wound (or any effect-channel damage) never
# crits, however certain the tuning.
func _crit_is_attack_channel_only() -> void:
	Resolver.set_crit_tuning({"fixed_pct": 100.0, "per_speed_pct": 0.0, "max_pct": 100.0})
	var tgt := _unit(0, 9, 0)
	var out := Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, -3, _unit(1, 5, 0)))
	check(not out.crit, "a non-attack (poison/effect) wound is never a crit")
	check_eq(tgt.current_health, 6, "the wound lands at its base amount")
	var out2 := Resolver.submit(StatMutation.make(tgt, StatMutation.DAMAGE, 3, _unit(1, 5, 0),
			StatMutation.CH_EFFECT))
	check(not out2.crit, "effect-channel damage is never a crit")
	check_eq(out2.delta, -3, "the effect damage lands at its base amount")


# The master switch: with crit disabled, even a certain-crit attacker lands base damage.
func _toggle_off_never_crits() -> void:
	Resolver.set_crit_tuning({"fixed_pct": 100.0, "per_speed_pct": 0.0, "max_pct": 100.0})
	Resolver.crit_enabled = false
	var tgt := _unit(0, 9, 0)
	var out := Resolver.submit(StatMutation.damage(tgt, 4, _unit(1, 5, 0)))
	check(not out.crit, "crit_enabled = false suppresses the roll entirely")
	check_eq(out.delta, -4, "the strike lands at base damage with crit disabled")
	Resolver.crit_enabled = true


func _near(got: float, want: float, label: String) -> void:
	check(absf(got - want) < EPS, "%s (got %.4f)" % [label, got])


# A bare unit with just a speed, for the pure chance tests (crit's owner is the ATTACKER, so
# these are attacker speeds where dodge's were target speeds).
func _spd(speed: int) -> CardInstance:
	return _unit(speed, 9, 0)


# A bare unit with explicit speed / health / shield (+ optional composition / side) — no effects,
# so its stats are exactly what get_attribute reads in the clean env. Always carries a pawn piece
# so it's a UNIT (elements-only cards are SPELLs, which the stat fold deliberately skips).
func _unit(speed: int, health: int, shield: int, elements: Array = [], owner: int = 0) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_crit_unit", "display_name": "Striker",
		"cost": 1, "attack": 1, "health": health, "speed": speed, "shield": shield,
		"elements": elements, "chess_pieces": ["pawn"],
	}))
	inst.owner = owner
	return inst


# A rook-composition building attacker — crit deliberately does NOT exclude buildings.
func _building() -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_crit_building", "display_name": "Wall",
		"cost": 1, "attack": 1, "health": 9, "speed": 0, "chess_pieces": ["rook"],
	}))
	inst.owner = 0
	return inst
