class_name Game
extends GameEntity

# The Game entity (Core System Design §1): bears the base rules and their stats — the
# numbers the base rules consume (Mutation §2). Held by the world as a plain member,
# housed in no container; it belongs to no side. It houses the two Sides in its
# container `sides`.
#
# The base rules (Combat Frame §4): ordinary effects triggered on `round_started`,
# running in their declared order — the round count, the untap, the ramp, the refill,
# the draw. Each is stateless machinery, constructed once and shared across every Game
# and every simulated world (the Mutation §4 lifecycle).
#
# The stats: `round`; the frame's seeds (starting mana capacity 1, ramp 1, turn draw 1,
# opening hand 3 — Combat Frame §4); the strike numbers (Mutation §7) — per mechanic:
# base, speed rating, difference rating, cap; plus the crit multiplier and its cap.
# Seeded with the ruled values, mutable through the road like any stat. Percent values;
# the multipliers flat.

static var _base_rules: Array[Effect] = []


func _init() -> void:
	super._init(null)
	seed_stat(&"starting_mana_capacity", 1.0)
	seed_stat(&"mana_ramp", 1.0)
	seed_stat(&"turn_draw", 1.0)
	seed_stat(&"opening_hand_size", 3.0)
	seed_stat(&"dodge_base", 0.0)
	seed_stat(&"dodge_speed_rating", 1.0)
	seed_stat(&"dodge_difference_rating", 4.0)
	seed_stat(&"dodge_cap", 75.0)
	seed_stat(&"crit_base", 5.0)
	seed_stat(&"crit_speed_rating", 1.0)
	seed_stat(&"crit_difference_rating", 0.0)
	seed_stat(&"crit_cap", 75.0)
	seed_stat(&"crit_multiplier", 2.0)
	seed_stat(&"crit_multiplier_cap", 5.0)
	effects.append_array(_rules())


static func _rules() -> Array[Effect]:
	if not _base_rules.is_empty():
		return _base_rules

	# 1. The round count rule — raises the Game's `round` by one. No resolver: the
	# default targets the Game.
	var count_payload: Array[Mutator] = []
	var count := StatMutationMutator.new()
	count.stat = &"round"
	count.delta = 1
	count_payload.append(count)
	_base_rules.append(Effect.new(_on_round_started(), null, count_payload))

	# 2. The untap rule — clears every fielded unit's tapped.
	var fielded_units: Array[EntityCondition] = []
	fielded_units.append(IsUnitCondition.new())
	fielded_units.append(BakedConditions.Fielded.new())
	var untap_payload: Array[Mutator] = []
	untap_payload.append(UntapMutator.new())
	_base_rules.append(Effect.new(_on_round_started(),
			TargetResolver.new(fielded_units, AllDecision.new()), untap_payload))

	# 3. The ramp rule — raises each side's mana_capacity by the ramp amount.
	var ramp_payload: Array[Mutator] = []
	ramp_payload.append(RampMutator.new())
	_base_rules.append(Effect.new(_on_round_started(), _each_side(), ramp_payload))

	# 4. The refill rule — raises each side's mana to its capacity.
	var refill_payload: Array[Mutator] = []
	refill_payload.append(RefillMutator.new())
	_base_rules.append(Effect.new(_on_round_started(), _each_side(), refill_payload))

	# 5. The draw rule — each side draws the turn draw from its deck.
	var draw_payload: Array[Mutator] = []
	var draw := DrawMutator.new()
	draw.count = -1
	draw_payload.append(draw)
	_base_rules.append(Effect.new(_on_round_started(), _each_side(), draw_payload))

	return _base_rules


static func _on_round_started() -> Trigger:
	var trigger := Trigger.new()
	trigger.event = &"round_started"
	return trigger


static func _each_side() -> TargetResolver:
	var sides: Array[EntityCondition] = []
	sides.append(BakedConditions.IsSide.new())
	return TargetResolver.new(sides, AllDecision.new())


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append_array([&"round",
			&"starting_mana_capacity", &"mana_ramp", &"turn_draw", &"opening_hand_size",
			&"dodge_base", &"dodge_speed_rating", &"dodge_difference_rating", &"dodge_cap",
			&"crit_base", &"crit_speed_rating", &"crit_difference_rating", &"crit_cap",
			&"crit_multiplier", &"crit_multiplier_cap"])
	return out


func _declared_containers() -> Array[StringName]:
	var out: Array[StringName] = super._declared_containers()
	out.append(&"sides")
	return out
