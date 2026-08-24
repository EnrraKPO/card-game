class_name PayCostRequest
extends EngineRequest

# Asks the PayCostProcedure: commit the cost — mana down on the target side, tap spent
# on the source — and produce the engaged event (Mutation §7). The engaged event's name
# derives from the occasion (play → play_engaged, use_ability → ability_used, Core §10);
# requests are self-sufficient, so the issuing mutator performs that derivation and the
# request carries the result: `engaged_name`, with the asked ability's name in `ability`
# (empty for a play). The elected targets are appended by the delivery, not carried here
# (Core §8 accretion).

var mana: int = 0
var tap: int = 0
var engaged_name: StringName = &""
var ability: StringName = &""


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity,
		p_mana: int, p_tap: int, p_engaged_name: StringName, p_ability: StringName) -> void:
	super._init(p_mutator_kind, p_source, p_target)
	mana = p_mana
	tap = p_tap
	engaged_name = p_engaged_name
	ability = p_ability
