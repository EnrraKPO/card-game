class_name Game
extends GameEntity

# The Game entity (Core System Design §1): bears the base rules and their stats — the
# numbers the base rules consume (Mutation §2). Held by the world as a plain member,
# housed in no container; it belongs to no side (allegiance null). It houses the two
# Sides in its container `sides`.
#
# Its stat roster grows with the phases that consume it: `round` is the round count
# rule's subject and the frame's seeds land with the combat frame (Combat Frame §4). The
# strike numbers (Mutation §7) — per mechanic: base, speed rating, difference rating,
# cap; plus the crit multiplier and its cap — are seeded below with the ruled values,
# mutable through the road like any stat. Values are percent, the multipliers flat.


func _init() -> void:
	super._init(null)
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


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append_array([&"round",
			&"dodge_base", &"dodge_speed_rating", &"dodge_difference_rating", &"dodge_cap",
			&"crit_base", &"crit_speed_rating", &"crit_difference_rating", &"crit_cap",
			&"crit_multiplier", &"crit_multiplier_cap"])
	return out


func _declared_containers() -> Array[StringName]:
	var out: Array[StringName] = super._declared_containers()
	out.append(&"sides")
	return out
