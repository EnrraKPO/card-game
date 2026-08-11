extends TestCase

# The core DODGE rule (Arbitrator): an attack strike can be avoided outright based on the TARGET's
# speed. The chance is DATA-DRIVEN (data/combat_tuning.json → Arbitrator.dodge_chance):
#     fixed_pct + per_speed_pct × target_speed + per_speed_diff_pct × max(0, tgt − atk speed)
# capped at max_pct. A dodge zeroes the WHOLE hit before shield/health and reports Outcome.dodged.
# This is core combat, not an effect — so it's proven here rather than in the effect suites.
#
# Two halves: the CHANCE FORMULA is a pure function (no RNG — asserted directly against injected
# tuning), and the ROLL is exercised only at the certain (100%) and impossible (0%) ends, where
# the outcome is deterministic regardless of the RNG stream.

const EPS := 0.0005


func suite_name() -> String:
	return "Dodge"


func run() -> void:
	_chance_formula()
	_dodge_bonus_fold()
	_building_never_dodges()
	var prev := Arbitrator.dodge_enabled
	Arbitrator.dodge_enabled = true
	_certain_dodge_zeroes_attack()
	_impossible_dodge_lands_in_full()
	_dodge_is_attack_channel_only()
	_toggle_off_never_dodges()
	Arbitrator.dodge_enabled = prev
	Arbitrator.set_dodge_tuning({})   # drop the injected cache; later reads reload from disk


# The pure chance function, against the shipped starting tuning (fixed 0, per-speed 1%, per-diff
# 4%, cap 75%). No RNG involved — this is arithmetic.
func _chance_formula() -> void:
	Arbitrator.set_dodge_tuning({
		"fixed_pct": 0.0, "per_speed_pct": 1.0, "per_speed_diff_pct": 4.0, "max_pct": 75.0,
	})
	_near(Arbitrator.dodge_chance(_spd(5)), 0.05, "per-speed only: 1% × speed 5 = 5%")
	_near(Arbitrator.dodge_chance(_spd(6), _spd(2)), 0.22,
			"faster target: 1%×6 + 4%×(6−2) = 6% + 16% = 22%")
	_near(Arbitrator.dodge_chance(_spd(2), _spd(6)), 0.02,
			"slower target: edge term is one-sided — just the 2% per-speed, no penalty")
	_near(Arbitrator.dodge_chance(_spd(4), _spd(4)), 0.04,
			"equal speed: no edge bonus, just 4% per-speed")
	check_eq(Arbitrator.dodge_chance(null), 0.0, "a null target has no dodge chance")

	# Fixed base stacks on top of the per-speed term.
	Arbitrator.set_dodge_tuning({"fixed_pct": 10.0, "per_speed_pct": 1.0})
	_near(Arbitrator.dodge_chance(_spd(3)), 0.13, "fixed 10% + 1%×speed 3 = 13%")

	# The cap ceils the total, however large the terms get.
	Arbitrator.set_dodge_tuning({"per_speed_pct": 1.0, "per_speed_diff_pct": 4.0, "max_pct": 20.0})
	_near(Arbitrator.dodge_chance(_spd(6), _spd(0)), 0.20,
			"raw 6% + 24% = 30% is capped to the 20% ceiling")


# A building (rook composition) is a rooted structure — it never dodges, whatever its speed,
# bonus, or the tuning.
func _building_never_dodges() -> void:
	Arbitrator.set_dodge_tuning({"fixed_pct": 100.0, "per_speed_pct": 10.0, "per_speed_diff_pct": 0.0, "max_pct": 100.0})
	var building := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_dodge_building", "display_name": "Wall",
		"cost": 1, "attack": 1, "health": 9, "speed": 9, "chess_pieces": ["rook"],
	}))
	building.owner = 0
	check(building.data.is_building(), "the test unit is a building")
	check_eq(Arbitrator.dodge_chance(building), 0.0, "a building never dodges (100% + high speed still 0)")
	Arbitrator.submit(StatMutation.make(building, StatMutation.DODGE_BONUS, 50, null, StatMutation.CH_SYSTEM))
	check_eq(Arbitrator.dodge_chance(building), 0.0, "a dodge_bonus can't make a building dodge")


# The `dodge_bonus` stat: extra dodge percentage points, written through the Arbitrator and
# folded by get_attribute. (The standing-effect and interception routes into this stat are
# effect-layer behavior — banished with that machinery; the rebuild's suites re-cover them.)
func _dodge_bonus_fold() -> void:
	# Zero out the speed-derived terms so the bonus is the whole chance.
	Arbitrator.set_dodge_tuning({"fixed_pct": 0.0, "per_speed_pct": 0.0, "per_speed_diff_pct": 0.0, "max_pct": 100.0})
	var u := _unit(0, 5, 0)
	_near(Arbitrator.dodge_chance(u), 0.0, "no bonus, zero rates → 0% dodge")
	Arbitrator.submit(StatMutation.make(u, StatMutation.DODGE_BONUS, 25, null, StatMutation.CH_SYSTEM))
	check_eq(u.get_attribute("dodge_bonus"), 25, "a dodge_bonus modifier folds into get_attribute")
	_near(Arbitrator.dodge_chance(u), 0.25, "a +25 dodge_bonus adds 25% to the chance")

	# The cap bounds the bonus too — no unit is untouchable.
	Arbitrator.set_dodge_tuning({"per_speed_pct": 0.0, "max_pct": 20.0})
	_near(Arbitrator.dodge_chance(u), 0.20, "the cap ceils a bonus that would exceed it")


# At a certain (100%, uncapped) chance the target avoids the whole strike — no shield/health touched.
func _certain_dodge_zeroes_attack() -> void:
	Arbitrator.set_dodge_tuning({"fixed_pct": 100.0, "max_pct": 100.0})
	var tgt := _unit(1, 5, 3)
	var out := Arbitrator.submit(StatMutation.damage(tgt, 4, _unit(1, 5, 0)))
	check(out.dodged, "a certain-dodge target flags the strike as dodged")
	check_eq(out.delta, 0, "a dodged strike lands 0 total")
	check_eq(out.shield_absorbed, 0, "a dodged strike touches no shield")
	check_eq(out.health_damage, 0, "a dodged strike touches no health")
	check_eq(tgt.current_shield, 3, "the dodging unit keeps its full shield")
	check_eq(tgt.current_health, 5, "the dodging unit takes no wound")
	check(out.interceptions.is_empty(), "a dodge is not an interception (no phantom cue)")


# At a 0% chance the strike always resolves in full.
func _impossible_dodge_lands_in_full() -> void:
	Arbitrator.set_dodge_tuning({"fixed_pct": 0.0, "per_speed_pct": 0.0, "per_speed_diff_pct": 0.0})
	var tgt := _unit(9, 5, 0)   # high speed, but every rate is 0
	var out := Arbitrator.submit(StatMutation.damage(tgt, 4, null))
	check(not out.dodged, "a 0%-tuning target never dodges, however fast")
	check_eq(out.delta, -4, "the strike lands in full at 0% dodge")
	check_eq(tgt.current_health, 1, "the target is wounded normally")


# Dodge is attack-channel only: a poison-form HEALTH mutation is never dodged, however certain.
func _dodge_is_attack_channel_only() -> void:
	Arbitrator.set_dodge_tuning({"fixed_pct": 100.0, "max_pct": 100.0})
	var tgt := _unit(1, 5, 0)
	var out := Arbitrator.submit(StatMutation.make(tgt, StatMutation.HEALTH, -3, null))
	check(not out.dodged, "a non-attack (poison/effect) wound is never dodged")
	check_eq(tgt.current_health, 2, "the poison wound lands despite a certain dodge chance")


# The master switch: with dodge disabled, even a certain-dodge target takes the full hit.
func _toggle_off_never_dodges() -> void:
	Arbitrator.set_dodge_tuning({"fixed_pct": 100.0, "max_pct": 100.0})
	Arbitrator.dodge_enabled = false
	var tgt := _unit(1, 5, 0)
	var out := Arbitrator.submit(StatMutation.damage(tgt, 4, null))
	check(not out.dodged, "dodge_enabled = false suppresses the roll entirely")
	check_eq(out.delta, -4, "the strike lands in full with dodge disabled")
	Arbitrator.dodge_enabled = true


func _near(got: float, want: float, label: String) -> void:
	check(absf(got - want) < EPS, "%s (got %.4f)" % [label, got])


# A bare unit with just a speed (health/shield default sensible), for the pure chance tests.
func _spd(speed: int) -> CardInstance:
	return _unit(speed, 9, 0)


# A bare unit with explicit speed / health / shield (+ optional composition / side) — no effects,
# so its stats are exactly what get_attribute reads in the clean env. Always carries a pawn piece
# so it's a UNIT (elements-only cards are SPELLs, which the stat fold deliberately skips).
func _unit(speed: int, health: int, shield: int, elements: Array = [], owner: int = 0) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_dodge_unit", "display_name": "Nimble",
		"cost": 1, "attack": 1, "health": health, "speed": speed, "shield": shield,
		"elements": elements, "chess_pieces": ["pawn"],
	}))
	inst.owner = owner
	return inst
