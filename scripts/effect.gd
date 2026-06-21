class_name Effect
extends RefCounted

# The single effect payload any game component can hold (cards, charms, upgrades, relics,
# heroes). One authored schema, three KINDS routed to the right evaluator:
#   • MODIFIER  — a passive delta on a value. scope=GLOBAL keys a registry number (see
#                 GameAttributes), resolved by GameData.value; scope=CARD keys a card
#                 attribute, folded into CardInstance.get_attribute at read-time for matching
#                 player cards (predicate selection via `filter`).
#   • TRIGGERED — an event-driven, targeted, conditional effect (the classic card effect).
#                 Dispatched from a card on the board (EffectSystem.trigger) AND at run level
#                 from any active source (EffectSystem.trigger_global).
#   • CUSTOM    — a code hook (EffectHooks) keyed by `custom_id`, for logic the schema can't
#                 express. Fired like a TRIGGERED effect; runs arbitrary code with the context.
# `from_dict` is the one parser; it infers the kind from the fields present, so existing card /
# charm / upgrade data loads unchanged.

enum Kind  { MODIFIER, TRIGGERED, CUSTOM }
enum Scope { GLOBAL, CARD }
enum Op    { ADD, MUL }   # ADD today; MUL reserved

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

# Card-scoped MODIFIER keys → the CardInstance attribute each one adjusts.
const CARD_ATTR := {
	"unit.attack": "attack",
	"unit.health": "max_health",
	"card.cost":   "cost",
}

var kind: Kind = Kind.TRIGGERED   # default keeps all existing (triggered) card/charm data valid

# Shared magnitude. Float so fractional keys (e.g. reward.king_piece_chance) work; the
# triggered/attribute path int()s it.
var amount: float = 0.0

# ── TRIGGERED / CUSTOM fields ──
var trigger: Trigger = Trigger.ON_PLAY
var targeting_policy: TargetingPolicy = TargetingPolicy.SELF
var conditions: Array = []   # Array[EffectCondition]
var attribute: String = ""
var custom_id: String = ""           # CUSTOM: id into EffectHooks
var custom_apply: Callable           # programmatic inline hook (not data-authored)

# ── MODIFIER fields ──
var scope: Scope = Scope.GLOBAL
var key: String = ""
var op: Op = Op.ADD
var filter: Dictionary = {}   # card selection predicate for scope=CARD


# The one canonical parser. Kind is explicit ("kind") or inferred: a "key" → MODIFIER, a
# "custom" → CUSTOM, otherwise TRIGGERED — so legacy data needs no migration.
static func from_dict(d: Dictionary) -> Effect:
	var e := Effect.new()
	e.amount = float(d.get("amount", 0))
	for c_data: Dictionary in d.get("conditions", []):
		e.conditions.append(EffectCondition.from_dict(c_data))
	var kind_str := str(d.get("kind", ""))
	if kind_str == "modifier" or (kind_str.is_empty() and d.has("key")):
		e.kind = Kind.MODIFIER
		e.key  = d.get("key", "")
		e.op   = Op.MUL if str(d.get("op", "add")) == "mul" else Op.ADD
		var f: Dictionary = d.get("filter", {})
		e.filter = f.duplicate()
		# Scope is inferred from the key (card attribute vs registry number); explicit wins.
		e.scope = Scope.CARD if CARD_ATTR.has(e.key) else Scope.GLOBAL
		if d.has("scope"):
			e.scope = Scope.CARD if str(d.get("scope")) == "card" else Scope.GLOBAL
	elif kind_str == "custom" or (kind_str.is_empty() and d.has("custom")):
		e.kind             = Kind.CUSTOM
		e.custom_id        = d.get("custom", "")
		e.trigger          = _str_trigger(d.get("trigger", ""))
		e.targeting_policy = _str_policy(d.get("targeting_policy", ""))
	else:
		e.kind             = Kind.TRIGGERED
		e.trigger          = _str_trigger(d.get("trigger", ""))
		e.targeting_policy = _str_policy(d.get("targeting_policy", ""))
		e.attribute        = d.get("attribute", "")
	return e


# Serialises back to the authored shape. Exercised for persisted (overridden) CARD effects,
# which are TRIGGERED — so that path matches the legacy dict exactly.
func to_dict() -> Dictionary:
	match kind:
		Kind.MODIFIER:
			var d := {"kind": "modifier", "key": key, "amount": amount}
			if op == Op.MUL:
				d["op"] = "mul"
			if not filter.is_empty():
				d["filter"] = filter
			return d
		Kind.CUSTOM:
			return {
				"kind":             "custom",
				"custom":           custom_id,
				"trigger":          trigger_key(trigger),
				"targeting_policy": policy_key(targeting_policy),
			}
		_:
			var conds: Array = []
			for c: EffectCondition in conditions:
				conds.append(c.to_dict())
			return {
				"trigger":          trigger_key(trigger),
				"targeting_policy": policy_key(targeting_policy),
				"attribute":        attribute,
				"amount":           amount_int(),
				"conditions":       conds,
			}


# ── MODIFIER helpers ─────────────────────────────────────────────────────────────────

func is_card_modifier() -> bool:
	return kind == Kind.MODIFIER and scope == Scope.CARD


func card_attribute() -> String:
	return CARD_ATTR.get(key, "")


func amount_int() -> int:
	return int(round(amount))


# Whether a card-scoped modifier applies to a given card. `unit.*` is implicitly fieldable
# units only (never spells or the King); `filter` narrows further (kind / has_element).
func matches_card(inst: CardInstance) -> bool:
	if inst == null or inst.data == null:
		return false
	var data := inst.data
	if key.begins_with("unit.") and (data.is_king or data.card_type == CardData.CardType.SPELL):
		return false
	match str(filter.get("kind", "")):
		"unit":
			if data.card_type != CardData.CardType.UNIT or data.is_king:
				return false
		"spell":
			if data.card_type != CardData.CardType.SPELL:
				return false
	if bool(filter.get("has_element", false)) and data.elements.is_empty():
		return false
	return true


# ── enum <-> string ──────────────────────────────────────────────────────────────────

static func _str_trigger(s: String) -> Trigger:
	match s:
		"on_play":         return Trigger.ON_PLAY
		"on_death":        return Trigger.ON_DEATH
		"on_attack":       return Trigger.ON_ATTACK
		"on_damage_taken": return Trigger.ON_DAMAGE_TAKEN
		"permanent":       return Trigger.PERMANENT
	return Trigger.ON_PLAY


static func _str_policy(s: String) -> TargetingPolicy:
	match s:
		"self":           return TargetingPolicy.SELF
		"single_nearest": return TargetingPolicy.SINGLE_NEAREST
		"single_random":  return TargetingPolicy.SINGLE_RANDOM
		"all_enemies":    return TargetingPolicy.ALL_ENEMIES
		"all_allies":     return TargetingPolicy.ALL_ALLIES
		"all":            return TargetingPolicy.ALL
		"manual":         return TargetingPolicy.MANUAL
	return TargetingPolicy.SELF


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
