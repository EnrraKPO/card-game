class_name EffectCondition
extends RefCounted

enum Comparator { GT, GTE, LT, LTE, EQ, NEQ }

var attribute: String = ""
var comparator: Comparator = Comparator.GTE
var value: int = 0
var custom_check: Callable
# STATUS-form condition: passes when the card's carrying of the named status matches `present`
# (e.g. { "status": "barrier", "present": false } = "only units without a Barrier"). When
# `status_id` is set, the attribute/comparator fields are ignored.
var status_id: String = ""
var present: bool = true
# COMPOSITION-form condition: passes when the card's composition (elements + chess pieces)
# contains ANY of the listed ids (`present: true`, the default) or NONE of them
# (`present: false`). The targeting-side twin of `subject_elements` (how Blinding Ward gates
# on light). E.g. { "composition": ["king", "queen"], "present": false } = "lackeys only" —
# gate a buff away from royal compositions so the persistent King doesn't hoard every buff.
var composition: Array = []
# ALLEGIANCE-form condition: passes on the tested unit's SIDE relative to the effect's
# OWNER (the container's side — every container has one, even holderless run-scope ones):
# "ally" = same side (the holder itself included — do not "fix" that), "enemy" = opposite.
# Replaces the old relation form's ally/enemy: allegiance is an owner question, never a
# holder question. Identity-with-holder ("self") is NOT a condition — it is structural
# (the `self` target kind / the trigger's participant gate); legacy {"relation": "self"}
# dicts are extracted by the resolver parsers before conditions are built.
var allegiance: String = ""
# CARD_TYPE-form condition: passes when the card is the named type ("unit" / "spell").
# The native replacement for the legacy `filter` {"kind": ...} narrowing.
var card_type: String = ""
# HAS_ELEMENT-form condition: passes when the card's composition contains at least one
# element (`true`) or none (`false`). Native replacement for filter {"has_element": true}.
var has_element_set := false
var has_element := false
# MUTATION-form condition: a predicate over a PENDING StatMutation rather than a unit —
# valid only on INTERCEPTOR effects (load-validated), evaluated by the Resolver's match
# via evaluate_mutation. "amount" is the one attribute today (e.g. {"mutation": "amount",
# "comparator": "gt", "value": 0} = "only heals" on a health intercept); the comparator
# machinery is shared with the attribute form.
var mutation_attr: String = ""


static func make(attr: String, comp: Comparator, val: int) -> EffectCondition:
	var c := EffectCondition.new()
	c.attribute = attr
	c.comparator = comp
	c.value = val
	return c


static func make_custom(check: Callable) -> EffectCondition:
	var c := EffectCondition.new()
	c.custom_check = check
	return c


# Parses an authored condition dict (inverse of to_dict). Used by Effect.from_dict so all
# effect/condition parsing lives in one place. A "status" key selects the status form, a
# "composition" key (single id or list) the composition form, an "allegiance" key the
# allegiance form. Legacy {"relation": "ally"/"enemy"} maps onto allegiance losslessly;
# legacy {"relation": "self"} is STRUCTURAL and must be extracted by the caller first
# (is_identity_dict) — one slipping through parses as vacuous-true, loudly.
static func from_dict(d: Dictionary) -> EffectCondition:
	if d.has("status"):
		var c := EffectCondition.new()
		c.status_id = str(d.get("status", ""))
		c.present = bool(d.get("present", true))
		return c
	if d.has("composition"):
		var c := EffectCondition.new()
		var comp: Variant = d.get("composition")
		c.composition = [str(comp)] if comp is String else (comp as Array).duplicate()
		c.present = bool(d.get("present", true))
		return c
	if d.has("allegiance") or d.has("relation"):
		var c := EffectCondition.new()
		c.allegiance = str(d.get("allegiance", d.get("relation", "")))
		if c.allegiance == "self":
			# Identity is not a predicate; the parsers extract it into structure. Reaching
			# here means a context we didn't cover — fail LOUD, degrade vacuous-true (the
			# self gate was vacuously true in every carrier-scoped legacy context).
			push_error("EffectCondition: unextracted {relation: self} — structural, not a condition: %s" % [d])
			c.allegiance = ""
		return c
	if d.has("card_type"):
		var c := EffectCondition.new()
		c.card_type = str(d.get("card_type", ""))
		return c
	if d.has("has_element"):
		var c := EffectCondition.new()
		c.has_element_set = true
		c.has_element = bool(d.get("has_element", true))
		return c
	if d.has("mutation"):
		var c := EffectCondition.new()
		c.mutation_attr = str(d.get("mutation", ""))
		if c.mutation_attr != "amount":
			push_error("EffectCondition: unknown mutation attribute '%s' — %s" % [c.mutation_attr, d])
		c.comparator = _str_comparator(d.get("comparator", ""))
		c.value = int(d.get("value", 0))
		return c
	return make(
		d.get("attribute", ""),
		_str_comparator(d.get("comparator", "")),
		int(d.get("value", 0))
	)


# Whether a RAW condition dict is the legacy identity form ({"relation": "self"}) — the
# resolver parsers consume these into structure (self target kind / trigger participant
# gate) before building the condition list.
static func is_identity_dict(d: Dictionary) -> bool:
	return str(d.get("relation", "")) == "self"


static func _str_comparator(s: String) -> Comparator:
	match s:
		"gt":  return Comparator.GT
		"gte": return Comparator.GTE
		"lt":  return Comparator.LT
		"lte": return Comparator.LTE
		"eq":  return Comparator.EQ
		"neq": return Comparator.NEQ
	return Comparator.GTE


# Inverse of CardData._parse_condition (custom_check is programmatic-only, not stored).
# Legacy {"relation": "ally"/"enemy"} input serializes as its canonical allegiance form —
# a deliberate native-schema migration (parse accepts both; emit converges on one).
func to_dict() -> Dictionary:
	if not status_id.is_empty():
		return {"status": status_id, "present": present}
	if not composition.is_empty():
		return {"composition": composition.duplicate(), "present": present}
	if not allegiance.is_empty():
		return {"allegiance": allegiance}
	if not card_type.is_empty():
		return {"card_type": card_type}
	if has_element_set:
		return {"has_element": has_element}
	if not mutation_attr.is_empty():
		return {"mutation": mutation_attr, "comparator": comparator_key(comparator), "value": value}
	return {
		"attribute":  attribute,
		"comparator": comparator_key(comparator),
		"value":      value,
	}


static func comparator_key(c: Comparator) -> String:
	match c:
		Comparator.GT:  return "gt"
		Comparator.GTE: return "gte"
		Comparator.LT:  return "lt"
		Comparator.LTE: return "lte"
		Comparator.EQ:  return "eq"
		Comparator.NEQ: return "neq"
	return "gte"


# `owner` is the SIDE of the effect this condition belongs to (the container's owner) —
# required by the allegiance form, ignored by every other form. -1 = no side known
# (allegiance then fails closed: you can't compare against a side that isn't there).
func is_mutation_form() -> bool:
	return not mutation_attr.is_empty()


# Evaluates a MUTATION-form condition against a pending StatMutation (the Resolver's
# interceptor match routes mutation-form conditions here, unit forms to evaluate()).
func evaluate_mutation(m: StatMutation) -> bool:
	if mutation_attr != "amount" or m == null:
		return false
	return _compare(m.amount)


func evaluate(card: CardInstance, owner: int = -1) -> bool:
	if is_mutation_form():
		return true   # not a unit predicate — routed to evaluate_mutation; vacuous here
	if custom_check.is_valid():
		return custom_check.call(card)
	if not allegiance.is_empty():
		if owner < 0:
			return false
		match allegiance:
			"ally":  return card.owner == owner
			"enemy": return card.owner >= 0 and card.owner != owner
		return false
	if not status_id.is_empty():
		return (card.find_status(status_id) != null) == present
	if not composition.is_empty():
		var has := false
		for id: String in composition:
			if card.data.elements.has(id) or card.data.chess_pieces.has(id):
				has = true
				break
		return has == present
	if not card_type.is_empty():
		var want_unit := card_type == "unit"
		return (card.data.card_type == CardData.CardType.UNIT) == want_unit
	if has_element_set:
		return card.data.elements.is_empty() != has_element
	return _compare(card.get_attribute(attribute))


# The one comparator application, shared by the attribute (unit) and mutation forms.
func _compare(actual: int) -> bool:
	match comparator:
		Comparator.GT:  return actual > value
		Comparator.GTE: return actual >= value
		Comparator.LT:  return actual < value
		Comparator.LTE: return actual <= value
		Comparator.EQ:  return actual == value
		Comparator.NEQ: return actual != value
	return false
