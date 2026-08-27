class_name StrikeRequest
extends EngineRequest

# Asks the StrikeProcedure (Kind Rosters §4). No parameters of its own: the striker is
# the source; the strike procedure reads its attack (Mutation §7).


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity) -> void:
	super._init(p_mutator_kind, p_source, p_target)
