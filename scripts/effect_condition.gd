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
# "composition" key (single id or list) the composition form.
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
	return make(
		d.get("attribute", ""),
		_str_comparator(d.get("comparator", "")),
		int(d.get("value", 0))
	)


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
func to_dict() -> Dictionary:
	if not status_id.is_empty():
		return {"status": status_id, "present": present}
	if not composition.is_empty():
		return {"composition": composition.duplicate(), "present": present}
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


func evaluate(card: CardInstance) -> bool:
	if custom_check.is_valid():
		return custom_check.call(card)
	if not status_id.is_empty():
		return (card.find_status(status_id) != null) == present
	if not composition.is_empty():
		var has := false
		for id: String in composition:
			if card.data.elements.has(id) or card.data.chess_pieces.has(id):
				has = true
				break
		return has == present
	var card_val := card.get_attribute(attribute)
	match comparator:
		Comparator.GT:  return card_val > value
		Comparator.GTE: return card_val >= value
		Comparator.LT:  return card_val < value
		Comparator.LTE: return card_val <= value
		Comparator.EQ:  return card_val == value
		Comparator.NEQ: return card_val != value
	return false
