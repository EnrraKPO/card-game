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
	ON_TURN_START,   # fired for every unit at the start of a combat round (status lifecycle)
	ON_TURN_END,     # fired for every unit at the end of a combat round; statuses then count down
	ON_ACTIVATE,     # fired for a unit when ITS turn comes up in the speed-ordered combat loop
}

# Sentinel for "apply this status for its own default duration" (the applier didn't override it).
const STATUS_DURATION_DEFAULT := -9999

enum TargetingPolicy {
	SELF,
	SINGLE_NEAREST,
	SINGLE_RANDOM,
	ALL_ENEMIES,
	ALL_ALLIES,
	ALL,
	MANUAL,
	ATTACK_TARGET,   # the unit this card is currently striking (valid in an ON_ATTACK context)
	SUBJECT,         # the unit the event is about (the activator/actor — see EffectContext.subject)
	ATTACKER,        # the unit that dealt the blow (valid in an ON_DAMAGE_TAKEN context)
}

# For an event-driven (TRIGGERED/CUSTOM) effect, which unit — relative to the effect's HOLDER — must
# be the event's subject for the effect to react. Default SELF means "I react only to my own action,"
# which reproduces pre-broadcast behaviour with no data migration. See EffectSystem._subject_matches.
enum SubjectFilter { SELF, ALLY, ENEMY, ANY }

# Card-scoped MODIFIER keys → the CardInstance attribute each one adjusts.
const CARD_ATTR := {
	"unit.attack": "attack",
	"unit.health": "max_health",
	"unit.speed":  "speed",
	"card.cost":   "cost",
}

var kind: Kind = Kind.TRIGGERED   # default keeps all existing (triggered) card/charm data valid

# Shared magnitude. Float so fractional keys (e.g. reward.king_piece_chance) work; the
# triggered/attribute path int()s it.
var amount: float = 0.0

# ── TRIGGERED / CUSTOM fields ──
var trigger: Trigger = Trigger.ON_PLAY
var subject_filter: SubjectFilter = SubjectFilter.SELF
var subject_elements: Array = []   # event subject must carry one of these elements (empty = any)
var targeting_policy: TargetingPolicy = TargetingPolicy.SELF
var conditions: Array = []   # Array[EffectCondition]
var attribute: String = ""
var custom_id: String = ""           # CUSTOM: id into EffectHooks
var custom_apply: Callable           # programmatic inline hook (not data-authored)

# Generic "apply a status" payload: any TRIGGERED effect may grant a status to each resolved
# target (in place of / as well as a stat delta). Empty status_id = this effect applies no status.
var status_id: String = ""
var status_duration: int = STATUS_DURATION_DEFAULT   # sentinel = use the status's own default
var status_stacks: int = 1

# ── MODIFIER fields ──
var scope: Scope = Scope.GLOBAL
var key: String = ""

# Which container owns this effect (kind + id), set by RelicData/StatusData at load — used by the
# combat cue (glint the relic chip / status pip) and by negate_attack (to record which status caused
# a miss). Empty for plain card effects. Never affects target resolution.
var owner_kind: String = ""
var owner_id: String = ""
# Probabilistic gate, rolled once before the effect resolves: the effect fires with this chance
# (1.0 = always). A declarative condition, separate from what the effect does. See EffectSystem.
var chance: float = 1.0
var op: Op = Op.ADD
var filter: Dictionary = {}   # card selection predicate for scope=CARD


# The one canonical parser. Kind is explicit ("kind") or inferred: a "key" → MODIFIER, a
# "custom" → CUSTOM, otherwise TRIGGERED — so legacy data needs no migration.
static func from_dict(d: Dictionary) -> Effect:
	var e := Effect.new()
	e.amount = float(d.get("amount", 0))
	e.chance = float(d.get("chance", 1.0))
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
		e.subject_filter   = _str_subject(d.get("subject", ""))
		e.subject_elements = (d.get("subject_elements", []) as Array).duplicate()
		e.targeting_policy = _str_policy(d.get("targeting_policy", ""))
	else:
		e.kind             = Kind.TRIGGERED
		e.trigger          = _str_trigger(d.get("trigger", ""))
		e.subject_filter   = _str_subject(d.get("subject", ""))
		e.subject_elements = (d.get("subject_elements", []) as Array).duplicate()
		e.targeting_policy = _str_policy(d.get("targeting_policy", ""))
		e.attribute        = d.get("attribute", "")
	# Optional "apply a status" payload, valid on any event-driven (TRIGGERED) effect.
	var st: Dictionary = d.get("status", {})
	if not st.is_empty():
		e.status_id       = str(st.get("id", ""))
		e.status_duration = int(st.get("duration", STATUS_DURATION_DEFAULT))
		e.status_stacks   = int(st.get("stacks", 1))
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
			var cd := {
				"kind":             "custom",
				"custom":           custom_id,
				"trigger":          trigger_key(trigger),
				"targeting_policy": policy_key(targeting_policy),
			}
			if subject_filter != SubjectFilter.SELF:
				cd["subject"] = subject_key(subject_filter)
			return cd
		_:
			var conds: Array = []
			for c: EffectCondition in conditions:
				conds.append(c.to_dict())
			var d := {
				"trigger":          trigger_key(trigger),
				"targeting_policy": policy_key(targeting_policy),
				"attribute":        attribute,
				"amount":           amount_int(),
				"conditions":       conds,
			}
			if subject_filter != SubjectFilter.SELF:
				d["subject"] = subject_key(subject_filter)
			if not subject_elements.is_empty():
				d["subject_elements"] = subject_elements
			if chance != 1.0:
				d["chance"] = chance
			if not status_id.is_empty():
				d["status"] = {"id": status_id, "duration": status_duration, "stacks": status_stacks}
			return d


# ── MODIFIER helpers ─────────────────────────────────────────────────────────────────

func is_card_modifier() -> bool:
	return kind == Kind.MODIFIER and scope == Scope.CARD


func card_attribute() -> String:
	return CARD_ATTR.get(key, "")


func amount_int() -> int:
	return int(round(amount))


# Whether a card-scoped modifier applies to a given card. `unit.*` keys apply to any unit
# (King/Queen included) but never to spell cards; `filter` narrows further (kind / has_element).
func matches_card(inst: CardInstance) -> bool:
	if inst == null or inst.data == null:
		return false
	var data := inst.data
	if key.begins_with("unit.") and data.card_type == CardData.CardType.SPELL:
		return false
	match str(filter.get("kind", "")):
		"unit":
			if data.card_type != CardData.CardType.UNIT:
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
		"on_turn_start":   return Trigger.ON_TURN_START
		"on_turn_end":     return Trigger.ON_TURN_END
		"on_activate":     return Trigger.ON_ACTIVATE
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
		"attack_target":  return TargetingPolicy.ATTACK_TARGET
		"subject":        return TargetingPolicy.SUBJECT
		"attacker":       return TargetingPolicy.ATTACKER
	return TargetingPolicy.SELF


static func _str_subject(s: String) -> SubjectFilter:
	match s:
		"self":  return SubjectFilter.SELF
		"ally":  return SubjectFilter.ALLY
		"enemy": return SubjectFilter.ENEMY
		"any":   return SubjectFilter.ANY
	return SubjectFilter.SELF


static func subject_key(f: SubjectFilter) -> String:
	match f:
		SubjectFilter.SELF:  return "self"
		SubjectFilter.ALLY:  return "ally"
		SubjectFilter.ENEMY: return "enemy"
		SubjectFilter.ANY:   return "any"
	return "self"


static func trigger_key(t: Trigger) -> String:
	match t:
		Trigger.ON_PLAY:         return "on_play"
		Trigger.ON_DEATH:        return "on_death"
		Trigger.ON_ATTACK:       return "on_attack"
		Trigger.ON_DAMAGE_TAKEN: return "on_damage_taken"
		Trigger.PERMANENT:       return "permanent"
		Trigger.ON_TURN_START:   return "on_turn_start"
		Trigger.ON_TURN_END:     return "on_turn_end"
		Trigger.ON_ACTIVATE:     return "on_activate"
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
		TargetingPolicy.ATTACK_TARGET:  return "attack_target"
		TargetingPolicy.SUBJECT:        return "subject"
		TargetingPolicy.ATTACKER:       return "attacker"
	return "self"
