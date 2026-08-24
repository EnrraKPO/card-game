class_name Game
extends GameEntity

# The Game entity (Core System Design §1): bears the base rules and their stats — the
# numbers the base rules consume (Mutation §2). Held by the world as a plain member,
# housed in no container; it belongs to no side (allegiance null). It houses the two
# Sides in its container `sides`.
#
# Its stat roster grows with the phases that consume it: the strike numbers land with the
# strike procedure (Mutation §7, Phase 2); the frame's seeds land with the combat frame
# (Combat Frame §4). `round` is the round count rule's subject (Combat Frame §4).


func _init() -> void:
	super._init(null)


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append(&"round")
	return out


func _declared_containers() -> Array[StringName]:
	var out: Array[StringName] = super._declared_containers()
	out.append(&"sides")
	return out
