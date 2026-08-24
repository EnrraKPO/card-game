class_name Plate
extends RefCounted

# The plate (Mutation System Design §5): the closed set of facts every issuance receives —
# the occasion (the event that fired the effect) and the holder (who holds the firing
# effect). The world is reached through the holder's world back-reference, and every
# question about game state is answerable through it — which is what lets the plate stay
# closed. The recipient is NOT here: it is a separate typed input beside the plate,
# supplied by the conductor's walk (null for a unique mutator).
#
# Conditions receive the same plate, with their typed subject likewise a separate input
# (Core §9).

var occasion: Event = null
var holder: GameEntity = null


func _init(p_occasion: Event, p_holder: GameEntity) -> void:
	occasion = p_occasion
	holder = p_holder


func world() -> World:
	return holder.world
