extends TestCase

# The core DODGE rule (Resolver._apply_damage): an attack strike can be avoided outright based
# on the TARGET's speed — DODGE_PER_SPEED (1%) per point, clamped to [0, 1]. A dodge zeroes the
# WHOLE hit before it touches shield or health, and reports Outcome.dodged so presentation can
# cue it (VFX/SFX/event hooks are a follow-up). This is core combat, not an effect — it lives in
# the Resolver's damage form, so it's proven here rather than in the effect suites.
#
# Determinism without seeding: a speed >= 100 unit clamps to chance 1.0, and randf() is always
# < 1.0 -> a guaranteed dodge; a speed-0 unit clamps to 0.0 -> randf() is never < 0.0 -> never
# dodges. So the pass/fail assertions don't depend on the RNG stream at all.


func suite_name() -> String:
	return "Dodge"


func run() -> void:
	# The harness disables dodge for the damage-math suites; turn it on for this one, restore
	# after (the runner only cleans the env once, before all suites).
	var prev := Resolver.dodge_enabled
	Resolver.dodge_enabled = true
	_certain_dodge_zeroes_attack()
	_zero_speed_never_dodges()
	_dodge_is_attack_channel_only()
	_toggle_off_never_dodges()
	Resolver.dodge_enabled = prev


# A guaranteed-dodge target (speed 100 -> chance clamps to 1.0) avoids the whole strike.
func _certain_dodge_zeroes_attack() -> void:
	var tgt := _nimble(100, 5, 3)
	var out := Resolver.submit(StatMutation.damage(tgt, 4, null))
	check(out.dodged, "a certain-dodge target flags the strike as dodged")
	check_eq(out.delta, 0, "a dodged strike lands 0 total")
	check_eq(out.shield_absorbed, 0, "a dodged strike touches no shield")
	check_eq(out.health_damage, 0, "a dodged strike touches no health")
	check_eq(tgt.current_shield, 3, "the dodging unit keeps its full shield")
	check_eq(tgt.current_health, 5, "the dodging unit takes no wound")
	check(out.interceptions.is_empty(), "a dodge is not an interception (no phantom cue)")


# A speed-0 target can never dodge (chance 0.0): the strike resolves in full.
func _zero_speed_never_dodges() -> void:
	var tgt := _nimble(0, 5, 0)
	var out := Resolver.submit(StatMutation.damage(tgt, 4, null))
	check(not out.dodged, "a speed-0 target never dodges")
	check_eq(out.delta, -4, "the strike lands in full against a speed-0 target")
	check_eq(tgt.current_health, 1, "the speed-0 target is wounded normally")


# Dodge is attack-channel only: a poison-form HEALTH mutation is never dodged, however nimble.
func _dodge_is_attack_channel_only() -> void:
	var tgt := _nimble(100, 5, 0)
	var out := Resolver.submit(StatMutation.make(tgt, StatMutation.HEALTH, -3, null))
	check(not out.dodged, "a non-attack (poison/effect) wound is never dodged")
	check_eq(tgt.current_health, 2, "the poison wound lands despite max dodge speed")


# The master switch: with dodge disabled, even a certain-dodge target takes the full hit.
func _toggle_off_never_dodges() -> void:
	Resolver.dodge_enabled = false
	var tgt := _nimble(100, 5, 0)
	var out := Resolver.submit(StatMutation.damage(tgt, 4, null))
	check(not out.dodged, "dodge_enabled = false suppresses the roll entirely")
	check_eq(out.delta, -4, "the strike lands in full with dodge disabled")
	Resolver.dodge_enabled = true


# A bare unit with an explicit speed / health / shield — no effects, so its stats are exactly
# what get_attribute reads in the clean env.
func _nimble(speed: int, health: int, shield: int) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_test_dodge_unit", "display_name": "Nimble",
		"cost": 1, "attack": 1, "health": health, "speed": speed, "shield": shield,
	}))
	inst.owner = 0
	return inst
