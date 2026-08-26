class_name MoveRequest
extends EngineRequest

# Asks the MoveProcedure (Core §2, A17): a move op elects the destination entity as its
# target; the mutator introduces the cargo. The container name resolves through the
# target's container map — one generic lookup (Mutation §7).

var cargo: GameEntity = null
var container_name: StringName = &""


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity,
		p_cargo: GameEntity, p_container_name: StringName) -> void:
	super._init(p_mutator_kind, p_source, p_target)
	cargo = p_cargo
	container_name = p_container_name
