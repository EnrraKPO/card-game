class_name BuryRequest
extends EngineRequest

# Asks the BuryProcedure (Core §6; Mutation §7): the target is the buried entity —
# the entity being moved is the target, so the request routes to its specific-purpose
# procedure.


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity) -> void:
	super._init(p_mutator_kind, p_source, p_target)
