class_name MarkupParse
extends RefCounted

# The one generic parse driver (Core System Design §9): a kind id resolves to its class
# through a static table; the driver fills the class's declared members by name from the
# markup, refusing unknown keys and type mismatches loudly; serialization is the mirror
# walk. Every authored member parses into its real type. A refusal returns null and the
# caller propagates it — nothing half-parsed survives.
#
# The tables hold the AUTHORED vocabulary only: machinery-only kinds (burial, pay,
# placement, tap; the Game default decision) never appear in markup and are absent here.
# Mutator roster parameters are required, every one (Mutation §4); condition members
# default where unauthored (negate false).

static var CONDITION_KINDS: Dictionary = {
	"is_holder": IsHolderCondition,
	"has_status": HasStatusCondition,
	"name_is": NameIsCondition,
	"is_ally": IsAllyCondition,
	"is_enemy": IsEnemyCondition,
	"is_unit": IsUnitCondition,
	"is_side": IsSideCondition,
	"houses_me": HousesMeCondition,
}

static var MUTATOR_KINDS: Dictionary = {
	"strike": StrikeMutator,
	"stat_mutation": StatMutationMutator,
	"damage": DamageMutator,
	"status": StatusMutator,
	"draw": DrawMutator,
	"poison": PoisonMutator,
}

static var DECISION_KINDS: Dictionary = {
	"nearest": NearestDecision,
	"random": RandomDecision,
	"stat_ranked": StatRankedDecision,
	"hand_pick": HandPickDecision,
	"occasions_targets": OccasionsTargetsDecision,
}


# ── The effect ─────────────────────────────────────────────────────────────────────────
# {"trigger": {...}, "targeting": {...}?, "payload": [...]?, "windup": ""?, "contact": ""?}
# — targeting absent = the Game default (Core §4); payload absent = an empty delivery.

static func parse_effect(markup: Dictionary) -> Effect:
	for key: String in markup:
		if not ["trigger", "targeting", "payload", "windup", "contact"].has(key):
			push_error("MarkupParse: effect key '%s' is a stranger — refused" % key)
			return null
	if not markup.has("trigger"):
		push_error("MarkupParse: an effect without a trigger — refused")
		return null
	var trigger: Trigger = parse_trigger(markup.trigger)
	if trigger == null:
		return null
	var resolver: TargetResolver = null
	if markup.has("targeting"):
		resolver = parse_targeting(markup.targeting)
		if resolver == null:
			return null
	var payload: Array[Mutator] = []
	if markup.has("payload"):
		if not (markup.payload is Array):
			push_error("MarkupParse: a payload must be an array — refused")
			return null
		payload = parse_payload(markup.payload)
		if payload.size() != (markup.payload as Array).size():
			return null
	var effect := Effect.new(trigger, resolver, payload)
	for cue: String in ["windup", "contact"]:
		if markup.has(cue) and not (markup[cue] is String):
			push_error("MarkupParse: '%s' must be a presentation name — refused" % cue)
			return null
	if markup.has("windup"):
		effect.windup_presentation = StringName(markup.windup as String)
	if markup.has("contact"):
		effect.contact_presentation = StringName(markup.contact as String)
	return effect


static func serialize_effect(effect: Effect) -> Dictionary:
	var out: Dictionary = {"trigger": serialize_trigger(effect.trigger)}
	if not (effect.resolver.decision is GameDecision and effect.resolver.conditions.is_empty()):
		out["targeting"] = serialize_targeting(effect.resolver)
	if not effect.payload.is_empty():
		out["payload"] = serialize_payload(effect.payload)
	if effect.windup_presentation != &"":
		out["windup"] = String(effect.windup_presentation)
	if effect.contact_presentation != &"":
		out["contact"] = String(effect.contact_presentation)
	return out


# ── The trigger (Core §9's authored form) ─────────────────────────────────────────────

static func parse_trigger(markup: Dictionary) -> Trigger:
	for key: String in markup:
		if not ["event", "eventdata_conditions", "entity_conditions"].has(key):
			push_error("MarkupParse: trigger key '%s' is a stranger — refused" % key)
			return null
	if not (markup.get("event") is String):
		push_error("MarkupParse: a trigger without its event condition — refused")
		return null
	var trigger := Trigger.new()
	trigger.event = StringName(markup.event as String)
	if markup.has("eventdata_conditions"):
		var block: Dictionary = markup.eventdata_conditions
		for key: String in block:
			if not ["policy", "conditions"].has(key):
				push_error("MarkupParse: eventdata_conditions key '%s' is a stranger — refused" % key)
				return null
		trigger.eventdata_policy = _parse_policy(block)
		if trigger.eventdata_policy == &"":
			return null
		for entry: Variant in block.get("conditions", []):
			var condition: Condition = parse_condition(entry)
			if condition == null:
				return null
			if not (condition is EventDataCondition):
				push_error("MarkupParse: kind in the eventdata list is not an EventDataCondition — refused")
				return null
			trigger.eventdata_conditions.append(condition)
	if markup.has("entity_conditions"):
		var block: Dictionary = markup.entity_conditions
		for key: String in block:
			if not ["policy", "entries"].has(key):
				push_error("MarkupParse: entity_conditions key '%s' is a stranger — refused" % key)
				return null
		trigger.entity_policy = _parse_policy(block)
		if trigger.entity_policy == &"":
			return null
		for entry: Variant in block.get("entries", []):
			var parsed: Trigger.EntityEntry = _parse_entity_entry(entry)
			if parsed == null:
				return null
			trigger.entity_entries.append(parsed)
	return trigger


static func serialize_trigger(trigger: Trigger) -> Dictionary:
	var out: Dictionary = {"event": String(trigger.event)}
	if not trigger.eventdata_conditions.is_empty():
		var conditions: Array = []
		for condition: EventDataCondition in trigger.eventdata_conditions:
			conditions.append(serialize_condition(condition))
		var block: Dictionary = {"conditions": conditions}
		if trigger.eventdata_policy != &"all":
			block["policy"] = String(trigger.eventdata_policy)
		out["eventdata_conditions"] = block
	if not trigger.entity_entries.is_empty():
		var entries: Array = []
		for entry: Trigger.EntityEntry in trigger.entity_entries:
			var conditions: Array = []
			for condition: EntityCondition in entry.conditions:
				conditions.append(serialize_condition(condition))
			var serialized: Dictionary = {"route": String(entry.route), "conditions": conditions}
			if entry.negate:
				serialized["negate"] = true
			entries.append(serialized)
		var block: Dictionary = {"entries": entries}
		if trigger.entity_policy != &"all":
			block["policy"] = String(trigger.entity_policy)
		out["entity_conditions"] = block
	return out


static func _parse_policy(block: Dictionary) -> StringName:
	var policy: Variant = block.get("policy", "all")
	if not (policy is String) or not ["all", "any"].has(policy):
		push_error("MarkupParse: policy must be 'all' or 'any' — refused")
		return &""
	return StringName(policy as String)


static func _parse_entity_entry(markup: Variant) -> Trigger.EntityEntry:
	if not (markup is Dictionary):
		push_error("MarkupParse: an entity entry must be an object — refused")
		return null
	for key: String in (markup as Dictionary):
		if not ["route", "negate", "conditions"].has(key):
			push_error("MarkupParse: entity entry key '%s' is a stranger — refused" % key)
			return null
	var route: Variant = (markup as Dictionary).get("route")
	if not (route is String):
		push_error("MarkupParse: an entity entry without a route — refused")
		return null
	var entry := Trigger.EntityEntry.new()
	entry.route = StringName(route as String)
	var negate: Variant = (markup as Dictionary).get("negate", false)
	if not (negate is bool):
		push_error("MarkupParse: negate must be a bool — refused")
		return null
	entry.negate = negate
	for entry_markup: Variant in (markup as Dictionary).get("conditions", []):
		var condition: Condition = parse_condition(entry_markup)
		if condition == null:
			return null
		if not (condition is EntityCondition):
			push_error("MarkupParse: kind in an entity entry is not an EntityCondition — refused")
			return null
		entry.conditions.append(condition)
	return entry


# ── Conditions (Core §9) ───────────────────────────────────────────────────────────────

static func parse_condition(markup: Variant) -> Condition:
	if not (markup is Dictionary):
		push_error("MarkupParse: a condition must be an object — refused")
		return null
	var kind: Variant = (markup as Dictionary).get("kind")
	if not (kind is String) or not CONDITION_KINDS.has(kind):
		push_error("MarkupParse: unknown condition kind '%s' — refused" % str(kind))
		return null
	var condition: Condition = (CONDITION_KINDS[kind] as GDScript).new()
	if not _fill(condition, markup, ["kind"]):
		return null
	return condition


static func serialize_condition(condition: Condition) -> Dictionary:
	return _mirror(condition, _kind_of(condition, CONDITION_KINDS), [])


# ── Targeting (authored resolver; form under A7's delegation — B22) ───────────────────
# {"decision": "nearest" | {"stat_ranked": {...}}, "conditions": [...]?}

static func parse_targeting(markup: Dictionary) -> TargetResolver:
	for key: String in markup:
		if not ["decision", "conditions"].has(key):
			push_error("MarkupParse: targeting key '%s' is a stranger — refused" % key)
			return null
	if not markup.has("decision"):
		push_error("MarkupParse: authored targeting without a decision — refused")
		return null
	var decision: Decision = _parse_keyed(markup.decision, DECISION_KINDS, "decision") as Decision
	if decision == null:
		return null
	var conditions: Array[EntityCondition] = []
	for entry: Variant in markup.get("conditions", []):
		var condition: Condition = parse_condition(entry)
		if condition == null:
			return null
		if not (condition is EntityCondition):
			push_error("MarkupParse: kind in a resolver is not an EntityCondition — refused")
			return null
		conditions.append(condition)
	return TargetResolver.new(conditions, decision)


static func serialize_targeting(resolver: TargetResolver) -> Dictionary:
	var out: Dictionary = {"decision": _mirror_keyed(resolver.decision, DECISION_KINDS)}
	if not resolver.conditions.is_empty():
		var conditions: Array = []
		for condition: EntityCondition in resolver.conditions:
			conditions.append(serialize_condition(condition))
		out["conditions"] = conditions
	return out


# ── The payload (Mutation §3, §4) ──────────────────────────────────────────────────────
# A "payload" array; each entry names one mutator — a string where the mutator takes no
# authored parameters, an object naming the mutator with its typed parameters where it
# does. Every roster parameter is required.

static func parse_payload(markup: Variant) -> Array[Mutator]:
	var out: Array[Mutator] = []
	if not (markup is Array):
		push_error("MarkupParse: a payload must be an array — refused")
		return out
	for entry: Variant in (markup as Array):
		var mutator: Mutator = _parse_keyed(entry, MUTATOR_KINDS, "mutator") as Mutator
		if mutator == null:
			out.clear()
			return out
		out.append(mutator)
	return out


static func serialize_payload(payload: Array[Mutator]) -> Array:
	var out: Array = []
	for mutator: Mutator in payload:
		out.append(_mirror_keyed(mutator, MUTATOR_KINDS))
	return out


# ── The generic machinery ──────────────────────────────────────────────────────────────

# A keyed authored entry: "name" where the kind has no authored parameters, or
# {"name": {params}} — every declared parameter required, strangers refused.
static func _parse_keyed(entry: Variant, table: Dictionary, what: String) -> RefCounted:
	var name: String
	var params: Dictionary = {}
	if entry is String:
		name = entry
	elif entry is Dictionary and (entry as Dictionary).size() == 1:
		name = (entry as Dictionary).keys()[0]
		var value: Variant = (entry as Dictionary)[name]
		if not (value is Dictionary):
			push_error("MarkupParse: %s '%s' parameters must be an object — refused" % [what, name])
			return null
		params = value
	else:
		push_error("MarkupParse: a %s entry must be a name or one named object — refused" % what)
		return null
	if not table.has(name):
		push_error("MarkupParse: unknown %s '%s' — refused" % [what, name])
		return null
	var object: RefCounted = (table[name] as GDScript).new()
	var declared: Array[String] = _authored_members(object, [] if what != "mutator" else ["kind"])
	for member: String in declared:
		if not params.has(member):
			push_error("MarkupParse: %s '%s' omits required parameter '%s' — refused"
					% [what, name, member])
			return null
	if not _fill(object, params, [] if what != "mutator" else ["kind"]):
		return null
	return object


static func _mirror_keyed(object: RefCounted, table: Dictionary) -> Variant:
	var name: String = _kind_of(object, table)
	var members: Dictionary = _mirror(object, "", ["kind"])
	members.erase("kind")
	if members.is_empty():
		return name
	return {name: members}


# Fills the object's declared script members by name, refusing unknown keys and type
# mismatches loudly. `handled` keys are the caller's own (already consumed).
static func _fill(object: Object, markup: Dictionary, handled: Array) -> bool:
	var declared: Dictionary = {}
	for property: Dictionary in object.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			declared[property.name] = property.type
	for key: Variant in markup:
		if handled.has(key):
			continue
		if not declared.has(key):
			push_error("MarkupParse: member '%s' is a stranger to %s — refused"
					% [str(key), _label(object)])
			return false
		var value: Variant = markup[key]
		match declared[key] as int:
			TYPE_STRING_NAME:
				if not (value is String):
					return _type_refusal(key, "a name")
				object.set(key, StringName(value as String))
			TYPE_INT:
				if value is int:
					object.set(key, value)
				elif value is float and is_equal_approx(value, floorf(value)):
					object.set(key, int(value))
				else:
					return _type_refusal(key, "an int")
			TYPE_FLOAT:
				if not (value is float or value is int):
					return _type_refusal(key, "a number")
				object.set(key, float(value))
			TYPE_BOOL:
				if not (value is bool):
					return _type_refusal(key, "a bool")
				object.set(key, value)
			_:
				return _type_refusal(key, "an authorable type")
	return true


# The mirror walk: every declared member back to markup, the kind id first where given.
static func _mirror(object: Object, kind: String, skip: Array) -> Dictionary:
	var out: Dictionary = {}
	if kind != "":
		out["kind"] = kind
	for property: Dictionary in object.get_property_list():
		if not (property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if skip.has(property.name):
			continue
		var value: Variant = object.get(property.name)
		match property.type as int:
			TYPE_STRING_NAME:
				out[property.name] = String(value as StringName)
			TYPE_BOOL:
				if value == true:
					out[property.name] = true
				elif property.name != "negate":
					out[property.name] = false
			_:
				out[property.name] = value
	return out


static func _authored_members(object: Object, skip: Array) -> Array[String]:
	var out: Array[String] = []
	for property: Dictionary in object.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and not skip.has(property.name):
			out.append(property.name)
	return out


static func _kind_of(object: Object, table: Dictionary) -> String:
	for name: String in table:
		if object.get_script() == table[name]:
			return name
	push_error("MarkupParse: %s has no kind id in its table" % _label(object))
	return ""


static func _type_refusal(key: Variant, wanted: String) -> bool:
	push_error("MarkupParse: member '%s' is not %s — refused" % [str(key), wanted])
	return false


static func _label(object: Object) -> String:
	var script: Script = object.get_script()
	return script.get_global_name() if script != null else "object"
