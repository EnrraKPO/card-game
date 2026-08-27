class_name StatMutationEventData
extends EventData

# Carries stat and delta (Kind Rosters §5) — the fact of a stat having moved.

var stat: StringName = &""
var delta: int = 0


func _init(p_stat: StringName, p_delta: int) -> void:
	stat = p_stat
	delta = p_delta
