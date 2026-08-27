class_name DamageRequest
extends EngineRequest

# Asks the DamageProcedure: deal the amount to the target — shield absorbs first,
# remainder to health (Kind Rosters §4).

var amount: int = 0


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity,
		p_amount: int) -> void:
	super._init(p_mutator_kind, p_source, p_target)
	amount = p_amount
