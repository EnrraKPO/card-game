class_name TriggerResolver
extends RefCounted

# The injectable component that decides WHETHER an effect activates — the "when" of an
# effect, fully separated from its targeting (the "who"). Every event-driven Effect holds
# exactly one resolver; the dispatch pipeline (EffectSystem) only ever asks it
# `fires(event, holder)` and knows nothing about subjects, participants or filters.
#
# Kinds (inner classes — ONE file on purpose: the factory below constructs them during
# other classes' @static_initializer runs, and separate files hit the static-init load
# order, leaving half-parsed scripts):
#   • Transient — no event: the effect applies as part of its own use (a spell cast, an
#                 ability activation). Never fires from dispatch.
#   • While     — no event: a STANDING effect, live for as long as its tracker is valid
#                 (see EffectTracker / LiveEffects). Never dispatched, never applied on
#                 use — the read path evaluates it continuously against the current board.
#   • Simple    — an origin-only event (play/death/activate/turn_start/turn_end) gated by
#                 one plain-condition list evaluated against the origin.
#   • Dual      — a two-participant event (attack/struck) gated by TWO condition lists:
#                 ORIGIN_CONDITIONS and DESTINATION_CONDITIONS, AND-ed. A non-empty list
#                 on a missing participant fails (never fires).
#
# Conditions are plain EffectConditions (stat / status / composition / allegiance) —
# true PREDICATES only. "Reacts only to its own action" is NOT a condition: it is the
# structural PARTICIPANT GATE ("of": "self" — the watched participant must BE the holder),
# a field on the event kinds. Allegiance ("an ally died") stays a condition, compared
# against the holder's side. Legacy {"relation": "self"} condition dicts (both the old
# subject mapping and Tool-authored native lists) are extracted into the gate at parse.
#
# Authoring: the effect's "trigger" key. A STRING is the legacy schema
# ("on_attack" + "subject" + "subject_elements") and maps losslessly onto a resolver here
# (zero data migration); a DICTIONARY is the native form:
#   { "kind": "transient" }
#   { "kind": "while" }
#   { "kind": "event", "event": "death", "of": "self", "conditions": [ ... ] }
#   { "kind": "dual_event", "event": "struck", "origin_of": "any", "destination_of": "self",
#     "origin_conditions": [ ... ], "destination_conditions": [ ... ] }
#   ("of" values: "self" = the holder only; "any" (default) = anyone's event)

const SIMPLE_EVENTS: Array[StringName] = [&"play", &"death", &"activate", &"turn_start", &"turn_end", &"permanent"]
const DUAL_EVENTS: Array[StringName] = [&"attack", &"struck", &"kill", &"dodge"]

# The allegiance anchor for condition evaluation is normally the HOLDER's side. Run-scope
# effects (relics/upgrades) have no holder unit — they anchor to the PLAYER (0) instead, so
# "ally"/"enemy" read relative to the player no matter whose event fired. Callers pass an
# explicit owner; this sentinel means "derive from the holder" (the board default).
const OWNER_FROM_HOLDER := -9999


# The allegiance side for a (holder, owner) pair: an explicit owner wins; otherwise the
# holder's side, or -1 when there is no holder (matches nobody — fail-closed).
static func anchor_owner(holder: CardInstance, owner: int) -> int:
	if owner != OWNER_FROM_HOLDER:
		return owner
	return holder.owner if holder != null else -1

# Legacy trigger key → (event id, whether the legacy single subject was the DESTINATION).
# `permanent` is intercepted in from_legacy before this map is consulted: it becomes the
# While kind (a standing effect) — the meaning that dangling slot always wanted.
const LEGACY_EVENTS := {
	"on_play":         [&"play", false],
	"on_death":        [&"death", false],
	"on_attack":       [&"attack", false],
	"on_damage_taken": [&"struck", true],
	"permanent":       [&"permanent", false],
	"on_turn_start":   [&"turn_start", false],
	"on_turn_end":     [&"turn_end", false],
	"on_activate":     [&"activate", false],
}


# Cheap prefilter: could this resolver ever fire for this event id? (The dispatch tiers use
# it to collect candidates before the full gate runs.)
func listens(_event_id: StringName) -> bool:
	return false


# The full activation gate: does this effect fire for this event, held by this unit? `owner`
# is the allegiance anchor for conditions — omit it (OWNER_FROM_HOLDER) to derive from the
# holder (board effects); run-scope callers pass the player side (0) with a null holder.
func fires(_event: GameEvent, _holder: CardInstance, _owner: int = OWNER_FROM_HOLDER) -> bool:
	return false


# Whether the effect applies when its container is USED (spell cast / ability activation) —
# the direct-apply path, which never consults events.
func applies_on_use() -> bool:
	return false


# Native (dictionary) authored form.
func to_dict() -> Dictionary:
	return {}


# ── Kinds ────────────────────────────────────────────────────────────────────────────

class Transient extends TriggerResolver:
	# "Fires" as part of its container's own use — a spell being cast, an activated ability
	# being paid for. Never reacts to board events.
	func applies_on_use() -> bool:
		return true

	func to_dict() -> Dictionary:
		return {"kind": "transient"}


class While extends TriggerResolver:
	# A STANDING effect: live for as long as its tracker is valid, contributing at read time
	# (see LiveEffects). All base gates stay false — dispatch and the use path never touch it.
	func to_dict() -> Dictionary:
		return {"kind": "while"}


class Simple extends TriggerResolver:
	var event: StringName = &"play"
	var of_holder := false       # the participant gate: the origin must BE the holder
	var conditions: Array = []   # Array[EffectCondition] (predicates), tested on the origin

	func listens(event_id: StringName) -> bool:
		return event_id == event

	func fires(p_event: GameEvent, holder: CardInstance, owner: int = TriggerResolver.OWNER_FROM_HOLDER) -> bool:
		if p_event.id != event:
			return false
		# The identity gate is structural against the holder — meaningless for a holderless
		# run-scope container (a relic isn't a unit), so it's inert when holder is null.
		if of_holder and holder != null and p_event.origin != holder:
			return false
		return TriggerResolver.conditions_pass(conditions, p_event.origin,
				TriggerResolver.anchor_owner(holder, owner))

	# Legacy spells/units author their cast-time effects as "on_play"; the use path must
	# keep applying them (see SpellCaster) even though a play event also exists for placement.
	func applies_on_use() -> bool:
		return event == &"play"

	func to_dict() -> Dictionary:
		var d := {"kind": "event", "event": String(event)}
		if of_holder:
			d["of"] = "self"
		if not conditions.is_empty():
			d["conditions"] = TriggerResolver.conditions_to_dicts(conditions)
		return d


class Dual extends TriggerResolver:
	var event: StringName = &"attack"
	var origin_of_holder := false            # participant gates, one per slot
	var destination_of_holder := false
	var origin_conditions: Array = []        # Array[EffectCondition] (predicates)
	var destination_conditions: Array = []   # Array[EffectCondition] (predicates)
	# The CAUSE gate (the `kill` event): when non-empty, the event's cause must match — a
	# specific id ("poison" ⇒ event.cause_id) or a kind ("attack" ⇒ event.cause_kind). This
	# is a structural gate like origin_of, not a unit predicate: the cause is not a unit, so
	# it can't be an EffectCondition. Empty = fires regardless of cause.
	var cause: StringName = &""

	func listens(event_id: StringName) -> bool:
		return event_id == event

	func fires(p_event: GameEvent, holder: CardInstance, owner: int = TriggerResolver.OWNER_FROM_HOLDER) -> bool:
		if p_event.id != event:
			return false
		if cause != &"" and p_event.cause_id != cause and p_event.cause_kind != cause:
			return false
		# Identity gates are inert for a holderless run-scope container (see Simple.fires).
		if origin_of_holder and holder != null and p_event.origin != holder:
			return false
		if destination_of_holder and holder != null and p_event.destination != holder:
			return false
		var anchor := TriggerResolver.anchor_owner(holder, owner)
		if not TriggerResolver.conditions_pass(origin_conditions, p_event.origin, anchor):
			return false
		return TriggerResolver.conditions_pass(destination_conditions, p_event.destination, anchor)

	func to_dict() -> Dictionary:
		var d := {"kind": "dual_event", "event": String(event)}
		if origin_of_holder:
			d["origin_of"] = "self"
		if destination_of_holder:
			d["destination_of"] = "self"
		if cause != &"":
			d["cause"] = String(cause)
		if not origin_conditions.is_empty():
			d["origin_conditions"] = TriggerResolver.conditions_to_dicts(origin_conditions)
		if not destination_conditions.is_empty():
			d["destination_conditions"] = TriggerResolver.conditions_to_dicts(destination_conditions)
		return d


# ── Parsing ──────────────────────────────────────────────────────────────────────────

# The one entry point Effect.from_dict uses. `trigger_value` is the raw "trigger" key
# (String = legacy, Dictionary = native); subject/subject_elements are the legacy
# companions, ignored for the native form.
static func parse(trigger_value: Variant, subject_key: String, subject_elements: Array) -> TriggerResolver:
	if trigger_value is Dictionary:
		return _from_native(trigger_value as Dictionary)
	return from_legacy(str(trigger_value), subject_key, subject_elements)


# Maps the legacy schema (trigger string + subject filter + subject elements) onto a
# resolver, applied to the participant that WAS the subject (the origin for every event
# except on_damage_taken, whose subject was the struck unit). Legacy subject "self"
# becomes the structural participant gate; ally/enemy become allegiance conditions.
static func from_legacy(trigger_key: String, subject_key: String, subject_elements: Array) -> TriggerResolver:
	if trigger_key == "permanent":
		return While.new()   # the legacy "permanent" trigger IS the standing kind
	var mapping: Array = LEGACY_EVENTS.get(trigger_key, LEGACY_EVENTS["on_play"])
	var event_id: StringName = mapping[0]
	var subject_is_destination: bool = mapping[1]

	var gate_self := false
	var conds: Array = []
	match subject_key:
		"ally":  conds.append(EffectCondition.from_dict({"allegiance": "ally"}))
		"enemy": conds.append(EffectCondition.from_dict({"allegiance": "enemy"}))
		"any":   pass   # no gate at all
		_:       gate_self = true   # legacy default: reacts only to its own action
	if not subject_elements.is_empty():
		conds.append(EffectCondition.from_dict({"composition": subject_elements.duplicate()}))

	if DUAL_EVENTS.has(event_id):
		var dual := Dual.new()
		dual.event = event_id
		if subject_is_destination:
			dual.destination_of_holder = gate_self
			dual.destination_conditions = conds
		else:
			dual.origin_of_holder = gate_self
			dual.origin_conditions = conds
		return dual
	var simple := Simple.new()
	simple.event = event_id
	simple.of_holder = gate_self
	simple.conditions = conds
	return simple


static func _from_native(d: Dictionary) -> TriggerResolver:
	match str(d.get("kind", "")):
		"transient":
			return Transient.new()
		"while":
			return While.new()
		"dual_event":
			var dual := Dual.new()
			dual.event = StringName(str(d.get("event", "attack")))
			dual.origin_of_holder = str(d.get("origin_of", "any")) == "self" \
					or _has_identity(d.get("origin_conditions", []))
			dual.destination_of_holder = str(d.get("destination_of", "any")) == "self" \
					or _has_identity(d.get("destination_conditions", []))
			dual.origin_conditions = _parse_conditions(d.get("origin_conditions", []))
			dual.destination_conditions = _parse_conditions(d.get("destination_conditions", []))
			dual.cause = StringName(str(d.get("cause", "")))
			return dual
		_:   # "event" (and anything unrecognised degrades to a simple event)
			var simple := Simple.new()
			simple.event = StringName(str(d.get("event", "play")))
			simple.of_holder = str(d.get("of", "any")) == "self" \
					or _has_identity(d.get("conditions", []))
			simple.conditions = _parse_conditions(d.get("conditions", []))
			return simple


# Identity dicts ({"relation": "self"} — the pre-gate native schema) are STRUCTURE, not
# predicates: they are read into the participant gate and never become conditions.
static func _has_identity(raw: Variant) -> bool:
	for c_data: Dictionary in (raw as Array):
		if EffectCondition.is_identity_dict(c_data):
			return true
	return false


static func _parse_conditions(raw: Variant) -> Array:
	var out: Array = []
	for c_data: Dictionary in (raw as Array):
		if EffectCondition.is_identity_dict(c_data):
			continue   # structural — consumed by the participant gate / self target kind
		out.append(EffectCondition.from_dict(c_data))
	return out


static func conditions_to_dicts(conds: Array) -> Array:
	var out: Array = []
	for c: EffectCondition in conds:
		out.append(c.to_dict())
	return out


# All conditions must pass against the given participant; a non-empty list on a MISSING
# participant fails (the agreed ruling: you can't gate on someone who isn't there).
# Conditions are predicates over (unit, owner-side): `owner` is the allegiance anchor (the
# holder's side for board effects, the player for run-scope — see anchor_owner). Identity
# gating is structural, never conditional.
static func conditions_pass(conds: Array, unit: CardInstance, owner: int) -> bool:
	if conds.is_empty():
		return true
	if unit == null:
		return false
	for c: EffectCondition in conds:
		if not c.evaluate(unit, owner):
			return false
	return true


# The compat Trigger enum value for this resolver — kept on Effect for the consumers that
# read effect.trigger without dispatching (the spell/ability "== ON_PLAY" include filter,
# enemy-AI heuristics). Derived, never authoritative.
static func legacy_trigger_for(event_id: StringName) -> Effect.Trigger:
	match event_id:
		&"death":       return Effect.Trigger.ON_DEATH
		&"attack":      return Effect.Trigger.ON_ATTACK
		&"struck":      return Effect.Trigger.ON_DAMAGE_TAKEN
		&"activate":    return Effect.Trigger.ON_ACTIVATE
		&"turn_start":  return Effect.Trigger.ON_TURN_START
		&"turn_end":    return Effect.Trigger.ON_TURN_END
		&"permanent":   return Effect.Trigger.PERMANENT
	return Effect.Trigger.ON_PLAY
