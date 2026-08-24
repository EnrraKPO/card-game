class_name Spell
extends Card

# A Spell (Core System Design §1): a Card kind. Its fixed machinery — the spell's burial
# effect, triggered by its own play (§6) — lands at the card-roads phase.


func _init(p_allegiance: Side = null) -> void:
	super._init(p_allegiance)
