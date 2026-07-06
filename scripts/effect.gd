class_name Effect
extends RefCounted

# The single effect payload any game component can hold (cards, charms, upgrades, relics,
# heroes). One authored schema, four KINDS routed to the right evaluator:
#   • MODIFIER    — a passive delta on a value. scope=GLOBAL keys a registry number (see
#                   GameAttributes), resolved by GameData.value; scope=CARD keys a card
#                   attribute, folded into CardInstance.get_attribute at read-time for matching
#                   player cards (predicate selection via `filter`).
#   • TRIGGERED   — an event-driven, targeted, conditional effect (the classic card effect).
#                   Dispatched from a card on the board (EffectSystem.trigger) AND at run level
#                   from any active source (EffectSystem.trigger_global).
#   • CUSTOM      — a code hook (EffectHooks) keyed by `custom_id`, for logic the schema can't
#                   express. Fired like a TRIGGERED effect; runs arbitrary code with the context.
#   • INTERCEPTOR — a standing rewrite of a pending StatMutation passing through the Resolver.
#                   NOT an event in time: it matches mutations by stat/channel/role and adjusts
#                   the amount BEFORE it commits (e.g. Blind: my outgoing attack damage ×0, half
#                   the time). Evaluated only inside Resolver.submit — never by the trigger
#                   dispatch. See Resolver._intercept.
# (Activated ABILITIES are not an effect kind: an ability is a definition holding ordinary
# effects behind a COST — see AbilityData. Containers reference abilities by id.)
# `from_dict` is the one parser; it infers the kind from the fields present, so existing card /
# charm / upgrade data loads unchanged.

enum Kind  { MODIFIER, TRIGGERED, CUSTOM, INTERCEPTOR }
enum Scope { GLOBAL, CARD }
enum Op    { ADD, MUL }   # MUL consumed by INTERCEPTOR rewrites (see Resolver._intercept); MODIFIERs are ADD-only today

# INTERCEPTOR: which side of the mutation the HOLDER must be for this to fire — the unit that
# caused it (SOURCE, e.g. Blind on the attacker) or the unit receiving it (TARGET, e.g. armor).
enum Role { SOURCE, TARGET }

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
	MANUAL_SLOT,     # a SLOT the player picks on their own side — may be EMPTY (the effect decides
	                 # what an empty pick means, e.g. material delivery spawns there); an occupied
	                 # pick is gated by the effect's conditions. See SpellCaster's slot-mode flow.
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
# THE activation gate: an injected TriggerResolver decides whether this effect fires for a
# given GameEvent (see scripts/triggers/). Authoritative for all dispatch. Built by
# from_dict from either the native form ("trigger" as a dictionary) or the legacy schema
# (trigger string + subject + subject_elements), which maps losslessly — zero migration.
var resolver: TriggerResolver = null
# Whether the trigger was authored in the native (dictionary) form — steers to_dict so both
# schemas round-trip byte-faithfully (legacy in → legacy out).
var authored_native_trigger := false
# THE targeting socket: an injected TargetResolver returns the unit(s) this effect
# affects, from the same shared context the trigger saw (event, holder, board). Built by
# from_dict from either the native form ("targets" as a dictionary) or the legacy
# "targeting_policy" string — zero migration.
var target_resolver: TargetResolver = null
var authored_native_targets := false
var _native_targets: Dictionary = {}   # raw native "targets" form; resolver built lazily
# Legacy/compat mirrors, kept for the consumers that classify effects WITHOUT resolving:
# the spell/ability "== ON_PLAY" include filter, SpellCaster's manual/slot mode checks and
# eligibility reads (conditions), enemy-AI heuristics. Derived for native-form effects;
# never consulted by dispatch.
var trigger: Trigger = Trigger.ON_PLAY
var subject_filter: SubjectFilter = SubjectFilter.SELF
var subject_elements: Array = []   # legacy companion of `trigger`; folded into the resolver
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

# ── INTERCEPTOR fields ──
var intercept: StringName = &""   # the StatMutation stat this rewrites (e.g. "damage")
var channel: StringName = &""     # provenance filter (e.g. "attack"); empty = any channel
var role: Role = Role.SOURCE      # which side of the mutation the holder must be

# Which container owns this effect (kind + id), set by RelicData/StatusData at load — used by the
# combat cue (glint the relic chip / status pip). Empty for plain card effects. Never affects
# target resolution.
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
	elif kind_str == "interceptor" or (kind_str.is_empty() and d.has("intercept")):
		e.kind      = Kind.INTERCEPTOR
		e.intercept = StringName(str(d.get("intercept", "")))
		e.channel   = StringName(str(d.get("channel", "")))
		e.role      = _str_role(str(d.get("role", "source")))
		e.op        = Op.MUL if str(d.get("op", "add")) == "mul" else Op.ADD
	elif kind_str == "custom" or (kind_str.is_empty() and d.has("custom")):
		e.kind             = Kind.CUSTOM
		e.custom_id        = d.get("custom", "")
		e._parse_trigger(d)
		e._parse_targets(d)
	else:
		e.kind             = Kind.TRIGGERED
		e._parse_trigger(d)
		e._parse_targets(d)
		e.attribute        = d.get("attribute", "")
		# Parsed for round-trip fidelity; no TRIGGERED evaluator consumes MUL today (the
		# INTERCEPTOR kind is where mul does its work — see Resolver._intercept).
		e.op               = Op.MUL if str(d.get("op", "add")) == "mul" else Op.ADD
	# Optional "apply a status" payload, valid on any event-driven (TRIGGERED) effect.
	var st: Dictionary = d.get("status", {})
	if not st.is_empty():
		e.status_id       = str(st.get("id", ""))
		e.status_duration = int(st.get("duration", STATUS_DURATION_DEFAULT))
		e.status_stacks   = int(st.get("stacks", 1))
	return e


# Parses the activation gate from either schema. Native form: "trigger" is a Dictionary
# (see TriggerResolver); the legacy compat fields are derived from it. Legacy form: the
# trigger string + subject + subject_elements keys, folded into an equivalent resolver.
func _parse_trigger(d: Dictionary) -> void:
	var trig_v: Variant = d.get("trigger", "on_play")
	if trig_v is Dictionary:
		authored_native_trigger = true
		resolver = TriggerResolver.parse(trig_v, "", [])
		trigger = _derived_legacy_trigger()
		return
	trigger          = _str_trigger(str(trig_v) if not str(trig_v).is_empty() else "on_play")
	subject_filter   = _str_subject(d.get("subject", ""))
	subject_elements = (d.get("subject_elements", []) as Array).duplicate()
	resolver = TriggerResolver.from_legacy(trigger_key(trigger), subject_key(subject_filter), subject_elements)


func _derived_legacy_trigger() -> Trigger:
	if resolver is TriggerResolver.Simple:
		return TriggerResolver.legacy_trigger_for((resolver as TriggerResolver.Simple).event)
	if resolver is TriggerResolver.Dual:
		return TriggerResolver.legacy_trigger_for((resolver as TriggerResolver.Dual).event)
	return Trigger.ON_PLAY   # transient behaves like on_play for the use-path filters


# The serialized "trigger" value: the native dictionary form when authored that way, the
# legacy string otherwise (kept out of the dict literals — the branches have no shared type).
func _trigger_out() -> Variant:
	if authored_native_trigger:
		return trigger_resolver().to_dict()
	return trigger_key(trigger)


# The activation resolver, lazily derived for programmatically-built effects (Effect.new()
# + field assignment, e.g. in tests) that never went through from_dict.
func trigger_resolver() -> TriggerResolver:
	if resolver == null:
		resolver = TriggerResolver.from_legacy(trigger_key(trigger), subject_key(subject_filter), subject_elements)
	return resolver


# Parses the targeting socket from either schema — WITHOUT constructing the resolver.
# Construction is deferred to targets_resolver(): data files parse during other classes'
# @static_initializer runs, when TargetResolver's script (whose signatures reach into the
# UI layer via EffectContext) may not be compiled yet. Only the raw form and the compat
# mirrors (targeting_policy enum + conditions list) are captured here.
func _parse_targets(d: Dictionary) -> void:
	var tv: Variant = d.get("targets", null)
	if tv is Dictionary:
		authored_native_targets = true
		_native_targets = (tv as Dictionary).duplicate(true)
		conditions = TriggerResolver._parse_conditions(_native_targets.get("conditions", []))
		targeting_policy = _policy_from_native(_native_targets)
		return
	targeting_policy = _str_policy(d.get("targeting_policy", ""))


# The targeting resolver, built on first use (runtime — never during static init).
func targets_resolver() -> TargetResolver:
	if target_resolver == null:
		if authored_native_targets:
			target_resolver = TargetResolver.parse(_native_targets)
			# the mirror and the resolver must share ONE condition list (see TargetResolver)
			target_resolver.conditions = conditions
		else:
			target_resolver = TargetResolver.from_legacy(policy_key(targeting_policy), conditions,
					trigger == Trigger.ON_DAMAGE_TAKEN)
	return target_resolver


# The compat TargetingPolicy for a native "targets" dict — derived from the raw strings so
# no TargetResolver construction is needed at parse time.
static func _policy_from_native(d: Dictionary) -> TargetingPolicy:
	match str(d.get("kind", "all")):
		"manual":      return TargetingPolicy.MANUAL
		"manual_slot": return TargetingPolicy.MANUAL_SLOT
		"auto":
			return TargetingPolicy.SINGLE_RANDOM if str(d.get("criterion", "nearest")) == "random" \
					else TargetingPolicy.SINGLE_NEAREST
		"participant":
			match str(d.get("participant", "holder")):
				"origin":      return TargetingPolicy.ATTACKER
				"destination": return TargetingPolicy.ATTACK_TARGET
				_:             return TargetingPolicy.SELF
	return TargetingPolicy.ALL


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
			if not conditions.is_empty():
				var mconds: Array = []
				for c: EffectCondition in conditions:
					mconds.append(c.to_dict())
				d["conditions"] = mconds
			return d
		Kind.CUSTOM:
			var cd := {
				"kind":    "custom",
				"custom":  custom_id,
				"trigger": _trigger_out(),
			}
			if authored_native_targets:
				cd["targets"] = targets_resolver().to_dict()
			else:
				cd["targeting_policy"] = policy_key(targeting_policy)
			if not authored_native_trigger and subject_filter != SubjectFilter.SELF:
				cd["subject"] = subject_key(subject_filter)
			return cd
		Kind.INTERCEPTOR:
			var idd := {
				"intercept": String(intercept),
				"role":      role_key(role),
				"amount":    amount,
			}
			if channel != &"":
				idd["channel"] = String(channel)
			if op == Op.MUL:
				idd["op"] = "mul"
			if chance != 1.0:
				idd["chance"] = chance
			return idd
		_:
			var d := {
				"trigger":   _trigger_out(),
				"attribute": attribute,
				"amount":    amount_int(),
			}
			if authored_native_targets:
				# the resolver owns the conditions in the native form — no top-level copy
				d["targets"] = targets_resolver().to_dict()
			else:
				d["targeting_policy"] = policy_key(targeting_policy)
				var conds: Array = []
				for c: EffectCondition in conditions:
					conds.append(c.to_dict())
				d["conditions"] = conds
			if not authored_native_trigger and subject_filter != SubjectFilter.SELF:
				d["subject"] = subject_key(subject_filter)
			if not authored_native_trigger and not subject_elements.is_empty():
				d["subject_elements"] = subject_elements
			if chance != 1.0:
				d["chance"] = chance
			if op == Op.MUL:
				d["op"] = "mul"
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


# Re-entrancy guard for condition-gated modifiers: evaluating a stat condition reads
# get_attribute, which folds modifiers back in — without the guard a modifier conditioned on
# its own attribute ("+1 attack while attack >= 5") recurses forever. While a modifier
# condition is being evaluated, nested condition-BEARING modifiers count as non-matching, so
# conditions see the unit as valued by its base + unconditional modifiers.
static var _in_modifier_condition := false

# Whether a card-scoped modifier applies to a given card — the card is the modifier's TARGET,
# and like every effect, targeting is gated by `conditions` (the full EffectCondition
# vocabulary: stat compares, status presence, composition). `unit.*` keys apply to any unit
# (King/Queen included) but never to spell cards; the legacy `filter` (kind / has_element)
# still narrows further.
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
	if not conditions.is_empty():
		if _in_modifier_condition:
			return false
		_in_modifier_condition = true
		for c: EffectCondition in conditions:
			if not c.evaluate(inst):
				_in_modifier_condition = false
				return false
		_in_modifier_condition = false
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
		"manual_slot":    return TargetingPolicy.MANUAL_SLOT
	return TargetingPolicy.SELF


static func _str_role(s: String) -> Role:
	return Role.TARGET if s == "target" else Role.SOURCE


static func role_key(r: Role) -> String:
	return "target" if r == Role.TARGET else "source"


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
		TargetingPolicy.MANUAL_SLOT:    return "manual_slot"
	return "self"
