class_name Card
extends GameEntity

# A Card (Core System Design §1): the base of the two kinds, Unit and Spell. Card
# machinery — the play effect (§5) and the payability query — lands at the card-roads
# phase; this type's standing facts are its stat: `cost`, seeded from the authored form
# at construction and mutable through the write road like any stat (§5).


func _init(p_allegiance: Side = null) -> void:
	super._init(p_allegiance)


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append(&"cost")
	return out
