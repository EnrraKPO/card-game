class_name Unit
extends Card

# A Unit (Core System Design §1): a Card kind. Its fixed machinery — the main action, the
# target poll, the placement effect, and the unit's burial effect — lands on its scheduled
# phases (Core §6, Combat Frame §6).
#
# Its stats: the strike pipeline reads `attack` and `speed`, damage lands on `shield`
# first then `health` (Mutation §7); `tapped` is the public mutable tap fact — zero is
# untapped, above zero is tapped, floored at zero by the WriteAuthority (Combat Frame §6).

# The building birth fact (envelope A7): a building never dodges (Mutation §7), is
# rooted, and receives no Move appointment (A9). Set at construction, never rewritten.
var is_building: bool = false


func _init(p_allegiance: Side = null) -> void:
	super._init(p_allegiance)


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append_array([&"attack", &"health", &"speed", &"shield", &"tapped"])
	return out
