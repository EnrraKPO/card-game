class_name Effect
extends RefCounted

enum Trigger {
	ON_PLAY,
	ON_DEATH,
	ON_ATTACK,
	ON_DAMAGE_TAKEN,
	PERMANENT,
}

enum TargetingPolicy {
	SELF,
	SINGLE_NEAREST,
	SINGLE_RANDOM,
	ALL_ENEMIES,
	ALL_ALLIES,
	ALL,
}

var trigger: Trigger = Trigger.ON_PLAY
var targeting_policy: TargetingPolicy = TargetingPolicy.SELF
var conditions: Array = []  # Array[EffectCondition]
var attribute: String = ""
var amount: int = 0
var custom_apply: Callable


static func make(
	p_trigger: Trigger,
	p_policy: TargetingPolicy,
	p_attribute: String,
	p_amount: int,
	p_conditions: Array = []
) -> Effect:
	var e := Effect.new()
	e.trigger = p_trigger
	e.targeting_policy = p_policy
	e.attribute = p_attribute
	e.amount = p_amount
	e.conditions = p_conditions.duplicate()
	return e


static func make_custom(
	p_trigger: Trigger,
	p_policy: TargetingPolicy,
	p_conditions: Array,
	apply_fn: Callable
) -> Effect:
	var e := Effect.new()
	e.trigger = p_trigger
	e.targeting_policy = p_policy
	e.conditions = p_conditions.duplicate()
	e.custom_apply = apply_fn
	return e
