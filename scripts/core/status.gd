class_name Status
extends GameEntity

# A Status (Core System Design §1): a plain GameEntity housed in its holder's `contained`
# container (Core §2 — no container beyond the declared). Minted and inserted by the
# StatusProcedure; a holder already carrying it
# has `stacks` added instead (Kind Rosters §4). `stacks` is a stat on the status.
#
# `status_id` is the status's kind identity — what `has_status` reads by checked downcast
# (Kind Rosters §1) and what the StatusProcedure matches when deciding mint-or-stack.

var status_id: StringName = &""


func _init(p_status_id: StringName = &"", p_allegiance: Side = null) -> void:
	super._init(p_allegiance)
	status_id = p_status_id


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append(&"stacks")
	return out
