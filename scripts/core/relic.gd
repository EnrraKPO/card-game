class_name Relic
extends GameEntity

# A Relic (Core System Design §1): a plain GameEntity — it holds effects and bears stats
# like any entity, and is housed in its Side's `relics` container. Its authored content
# arrives through the envelope (AMENDMENTS.html A7) at the card-roads phase.


func _init(p_allegiance: Side = null) -> void:
	super._init(p_allegiance)
