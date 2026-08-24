class_name ContainerMoveRequest
extends EngineRequest

# Asks the ContainerMoveProcedure: move the target from its housing to the destination.
# A destination is owner entity plus container name, and the name resolves through the
# owner's container map — one generic lookup (Core §2; Mutation §7).

var destination_owner: GameEntity = null
var destination_container: StringName = &""


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity,
		p_destination_owner: GameEntity, p_destination_container: StringName) -> void:
	super._init(p_mutator_kind, p_source, p_target)
	destination_owner = p_destination_owner
	destination_container = p_destination_container
