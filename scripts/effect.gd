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
	MANUAL,
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


# Serialises to the same dict shape CardData._parse_effect reads, so a persisted
# (overridden) card round-trips through CardData.build_from_dict. NOTE: a programmatic
# custom_apply effect can't be represented here — nothing uses one today, and such an
# effect on a player-ownable card would be dropped on save.
func to_dict() -> Dictionary:
	var conds: Array = []
	for c: EffectCondition in conditions:
		conds.append(c.to_dict())
	return {
		"trigger":          trigger_key(trigger),
		"targeting_policy": policy_key(targeting_policy),
		"attribute":        attribute,
		"amount":           amount,
		"conditions":       conds,
	}


static func trigger_key(t: Trigger) -> String:
	match t:
		Trigger.ON_PLAY:         return "on_play"
		Trigger.ON_DEATH:        return "on_death"
		Trigger.ON_ATTACK:       return "on_attack"
		Trigger.ON_DAMAGE_TAKEN: return "on_damage_taken"
		Trigger.PERMANENT:       return "permanent"
	return "on_play"


static func policy_key(p: TargetingPolicy) -> String:
	match p:
		TargetingPolicy.SELF:           return "self"
		TargetingPolicy.SINGLE_NEAREST: return "single_nearest"
		TargetingPolicy.SINGLE_RANDOM:  return "single_random"
		TargetingPolicy.ALL_ENEMIES:    return "all_enemies"
		TargetingPolicy.ALL_ALLIES:     return "all_allies"
		TargetingPolicy.ALL:            return "all"
		TargetingPolicy.MANUAL:         return "manual"
	return "self"
