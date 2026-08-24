class_name Side
extends GameEntity

# A Side (Core System Design §1): declares the `deck`, `hand`, `graveyard`, and `board`
# containers plus `relics`; mana is a stat on it (`mana_capacity` beside it, Combat Frame
# §4). Housed in the Game's `sides` container — player before enemy (Mutation §12).
#
# A Side's allegiance is itself: everything it houses belongs to it, and it belongs to no
# side but its own (BRIEFS.html B6).


func _init() -> void:
	super._init(null)
	_allegiance_ref = weakref(self)


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append_array([&"mana", &"mana_capacity"])
	return out


func _declared_containers() -> Array[StringName]:
	var out: Array[StringName] = super._declared_containers()
	out.append_array([&"deck", &"hand", &"graveyard", &"board", &"relics"])
	return out
