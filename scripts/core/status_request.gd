class_name StatusRequest
extends EngineRequest

# Asks the StatusProcedure: grant the target `stacks` of the status `status_id` — minted
# and inserted when the target does not carry it, stacks added when it does (Kind Rosters §4).

var status_id: StringName = &""
var stacks: int = 0


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity,
		p_status_id: StringName, p_stacks: int) -> void:
	super._init(p_mutator_kind, p_source, p_target)
	status_id = p_status_id
	stacks = p_stacks
