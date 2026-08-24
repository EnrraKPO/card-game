class_name StatMutationRequest
extends EngineRequest

# Asks the StatMutationProcedure: apply the delta to the target's stat (Mutation §6, §7).

var stat: StringName = &""
var delta: int = 0


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity,
		p_stat: StringName, p_delta: int) -> void:
	super._init(p_mutator_kind, p_source, p_target)
	stat = p_stat
	delta = p_delta
