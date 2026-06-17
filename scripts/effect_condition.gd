class_name EffectCondition
extends RefCounted

enum Comparator { GT, GTE, LT, LTE, EQ, NEQ }

var attribute: String = ""
var comparator: Comparator = Comparator.GTE
var value: int = 0
var custom_check: Callable


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


# Inverse of CardData._parse_condition (custom_check is programmatic-only, not stored).
func to_dict() -> Dictionary:
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
	var card_val := card.get_attribute(attribute)
	match comparator:
		Comparator.GT:  return card_val > value
		Comparator.GTE: return card_val >= value
		Comparator.LT:  return card_val < value
		Comparator.LTE: return card_val <= value
		Comparator.EQ:  return card_val == value
		Comparator.NEQ: return card_val != value
	return false
