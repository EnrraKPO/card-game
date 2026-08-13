class_name TriggerResolver
extends RefCounted

# The injectable component that decides WHETHER a triggered effect activates — the "when"
# of an effect, fully separated from its targeting (the "who"). Dispatch only ever asks
# `fires(event, holder)` and knows nothing about subjects, participants or filters.
#
# The Simple/Dual shape is ENDORSED AS-IS by the settled design (TARGETING_DESIGN.md §4.1:
# firing conditions belong to trigger implementations — Simple gates one participant list,
# Dual gates origin and destination independently). Everything legacy — the string-schema
# mapping, the subject-filter fold, the While standing tag, the compat enum derivation —
# was deleted with the effect layer (2026-08-11); this file carries only what the rebuilt
# TriggeredEffect stands on.
#
# Kinds (inner classes — ONE file on purpose: constructing them during other classes'
# @static_initializer runs hits the static-init load order with separate files):
#   • Simple — an origin-only event (play/death/act/turn_start/turn_end) gated by one
#     plain-condition list evaluated against the origin.
#   • Dual   — a two-participant event (attack/struck/kill/dodge/crit) gated by TWO
#     condition lists: origin and destination, AND-ed. A non-empty list on a missing
#     participant fails (never fires).
#   • Action — the trigger that owns no "when" (signed MAIN_ACTION_DESIGN.html,
#     amendment 3). It names no event and carries no conditions; dispatch never fires
#     it — only the unit's main-action appointment does (see MainActionHolder). An
#     effect whose trigger is Action-kind is thereby appointable as a main action.
#
# Conditions are plain EffectConditions — true PREDICATES only. "Reacts only to its own
# action" is NOT a condition: it is the structural PARTICIPANT GATE ("of": "self" — the
# watched participant must BE the holder), a field on the event kinds.
#
# Authoring (the native dictionary form):
#   { "kind": "event", "event": "death", "of": "self", "conditions": [ ... ] }
#   { "kind": "dual_event", "event": "struck", "origin_of": "any", "destination_of": "self",
#     "origin_conditions": [ ... ], "destination_conditions": [ ... ] }
#   { "kind": "action" }   — nothing further inside it; any further member is a stranger
#   ("of" values: "self" = the holder only; "any" (default) = anyone's event)

const SIMPLE_EVENTS: Array[StringName] = [&"play", &"death", &"act", &"turn_start", &"turn_end"]
const DUAL_EVENTS: Array[StringName] = [&"attack", &"struck", &"kill", &"dodge", &"crit"]

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


# Cheap prefilter: could this resolver ever fire for this event id? (Dispatch tiers use
# it to collect candidates before the full gate runs.)
func listens(_event_id: StringName) -> bool:
	return false


# The full activation gate: does this effect fire for this event, held by this unit? `owner`
# is the allegiance anchor for conditions — omit it (OWNER_FROM_HOLDER) to derive from the
# holder (board effects); run-scope callers pass the player side (0) with a null holder.
func fires(_event: GameEvent, _holder: CardInstance, _owner: int = OWNER_FROM_HOLDER) -> bool:
	return false


# Native (dictionary) authored form.
func to_dict() -> Dictionary:
	return {}


# ── Kinds ────────────────────────────────────────────────────────────────────────────

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


class Action extends TriggerResolver:
	# The Action kind: no "when" of its own. The base class's never-answers are this
	# kind's REAL answers — `listens` false keeps it out of every dispatch candidate
	# pool, `fires` false makes mis-routing structurally inert. The appointment (the
	# main-action holder) is the only thing that ever fires the effect carrying it.

	func to_dict() -> Dictionary:
		return {"kind": "action"}


# ── Parsing ──────────────────────────────────────────────────────────────────────────

# The one authored form. Anything else — the legacy string schema included — is refused
# loudly: the dead language is not parsed, it is re-authored.
static func parse(trigger_value: Variant) -> TriggerResolver:
	if not (trigger_value is Dictionary):
		push_error("TriggerResolver: '%s' is not the native trigger form (the legacy string schema was deleted 2026-08-11) — refusing" % str(trigger_value))
		return null
	var d := trigger_value as Dictionary
	match str(d.get("kind", "")):
		"dual_event":
			var dual := Dual.new()
			dual.event = StringName(str(d.get("event", "attack")))
			dual.origin_of_holder = str(d.get("origin_of", "any")) == "self"
			dual.destination_of_holder = str(d.get("destination_of", "any")) == "self"
			dual.origin_conditions = _parse_conditions(d.get("origin_conditions", []))
			dual.destination_conditions = _parse_conditions(d.get("destination_conditions", []))
			dual.cause = StringName(str(d.get("cause", "")))
			return dual
		"event":
			var simple := Simple.new()
			simple.event = StringName(str(d.get("event", "play")))
			simple.of_holder = str(d.get("of", "any")) == "self"
			simple.conditions = _parse_conditions(d.get("conditions", []))
			return simple
		"action":
			# Nothing further inside it (MAIN_ACTION_DESIGN.html amendment 3): the Action
			# trigger refuses every further member as a stranger, loudly — an action cannot
			# be written to look like a triggered effect, nor the reverse.
			if d.size() != 1:
				var strangers := d.keys().filter(func(k: Variant) -> bool: return str(k) != "kind")
				push_error("TriggerResolver: the Action trigger carries nothing — stranger member(s) %s refused" % [strangers])
				return null
			return Action.new()
	push_error("TriggerResolver: unknown trigger kind '%s' — refusing (no permissive default)" % str(d.get("kind", "")))
	return null


static func _parse_conditions(raw: Variant) -> Array:
	var out: Array = []
	for c_data: Dictionary in (raw as Array):
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
