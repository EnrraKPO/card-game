class_name EffectCondition
extends RefCounted

enum Comparator { GT, GTE, LT, LTE, EQ, NEQ }

var attribute: String = ""
var comparator: Comparator = Comparator.GTE
var value: int = 0
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
# COMPOSITION-COUNT form - the same `composition` list asking a QUANTITY instead of a
# presence: { "composition": ["fire"], "count": 2 } = "built from at least two fire"
# (the fire_fire units). `comparator` is shared with the attribute form and defaults to
# GTE; the tested number is the TOTAL occurrences of any listed id, so
# { "composition": ["fire","water"], "count": 2 } admits fire_fire, fire_water and
# water_water alike. -1 = not the count form (the presence form above).
#
# TWO LENSES, TWO QUESTIONS (settled with the user 2026-08-04) - the distinction that
# makes this coherent:
#   * PRESENCE ("is it fire?") reads the EFFECTIVE composition (LiveEffects) - the
#     "treated as" lens, where a blessing's grant lands. A blessed water pawn IS fire.
#   * COUNT ("is it built from two fire?") reads the card's REAL composition - identity.
#     A grant says a unit is to be TREATED AS fire; it never claimed how MUCH fire the
#     unit is, so it has nothing to contribute to a quantity. A blessed fire pawn is
#     fire, and is not fire_fire.
# This is why the count form needs no cap and cannot destabilise the Layer-1 grant fixed
# point: it never reads the grant set at all.
#
# The THRESHOLD itself lives in `value` and the test in `comparator` — the same machinery
# the attribute form uses (one comparator implementation, never a second). This flag only
# selects the form.
var composition_counted := false
# ALLEGIANCE-form condition: passes on the tested unit's SIDE relative to the effect's
# OWNER (the container's side — every container has one, even holderless run-scope ones):
# "ally" = same side (the holder itself included — do not "fix" that), "enemy" = opposite.
# Allegiance is an owner question, never a holder question. Identity-with-holder ("self")
# is NOT a condition — it is structural (the `self` target kind / the trigger's
# participant gate).
var allegiance: String = ""
# CARD_TYPE-form condition: passes when the card is the named type ("unit" / "spell").
# The native replacement for the legacy `filter` {"kind": ...} narrowing.
var card_type: String = ""
# HAS_ELEMENT-form condition: passes when the card's composition contains at least one
# element (`true`) or none (`false`). Native replacement for filter {"has_element": true}.
var has_element_set := false
var has_element := false
# UNTAPPED-form condition: passes while the unit's round action is unspent (`true`) or
# spent (`false`) — a plain ask-time read of CardInstance.attack_exhausted, nothing
# stored (signed ATTACK_SYSTEM_DESIGN.html §8.0: nearest_attack gates itself with it; the
# boolean's writer returns with the ActivatedEffect rebuild's tap costs).
var untapped_set := false
var untapped := true
# (The load-derived VIABILITY form — the prohibit-non-ops implicit condition — and the
# programmatic custom_check hook were deleted 2026-08-11: the viability installer died in
# the targeting demolition and orphaned implementations don't get kept, and inline code
# hooks are not authored data. The RULE survives in the design: every "is there any legal
# play" question is a query INTO the rebuilt target resolver, TARGETING_DESIGN.md §3.)
#
# MUTATION-form condition: a predicate over a PENDING StatMutation rather than a unit —
# the delivery-condition seat the interception system evaluates (TARGETING_DESIGN.md §8).
# "amount" is the one attribute today (e.g. {"mutation": "amount", "comparator": "gt",
# "value": 0} = "only heals" on a health intercept); the comparator machinery is shared
# with the attribute form.
var mutation_attr: String = ""


static func make(attr: String, comp: Comparator, val: int) -> EffectCondition:
	var c := EffectCondition.new()
	c.attribute = attr
	c.comparator = comp
	c.value = val
	return c


# Parses an authored condition dict (inverse of to_dict) — all condition parsing lives in
# one place. A "status" key selects the status form, a "composition" key (single id or
# list) the composition form, an "allegiance" key the allegiance form. Legacy
# {"relation": "ally"/"enemy"} maps onto allegiance losslessly; {"relation": "self"} is
# STRUCTURAL (the trigger's participant gate / the self target kind), never a condition —
# it parses as vacuous-true, loudly.
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
		if d.has("count"):
			# The QUANTITY form: identity-lensed, comparator-driven (default "at least N").
			# The threshold rides `value` — the shared comparator machinery, not a second one.
			c.composition_counted = true
			c.value = int(d.get("count", 0))
			c.comparator = _str_comparator(str(d.get("comparator", "gte")))
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
	if d.has("untapped"):
		var c := EffectCondition.new()
		c.untapped_set = true
		c.untapped = bool(d.get("untapped", true))
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


static func _str_comparator(s: String) -> Comparator:
	match s:
		"gt":  return Comparator.GT
		"gte": return Comparator.GTE
		"lt":  return Comparator.LT
		"lte": return Comparator.LTE
		"eq":  return Comparator.EQ
		"neq": return Comparator.NEQ
	return Comparator.GTE


# Inverse of from_dict. Legacy {"relation": "ally"/"enemy"} input serializes as its
# canonical allegiance form (parse accepts both; emit converges on one).
func to_dict() -> Dictionary:
	if not status_id.is_empty():
		return {"status": status_id, "present": present}
	if not composition.is_empty() and composition_counted:
		return {"composition": composition.duplicate(), "count": value,
				"comparator": comparator_key(comparator)}
	if not composition.is_empty():
		return {"composition": composition.duplicate(), "present": present}
	if not allegiance.is_empty():
		return {"allegiance": allegiance}
	if not card_type.is_empty():
		return {"card_type": card_type}
	if has_element_set:
		return {"has_element": has_element}
	if untapped_set:
		return {"untapped": untapped}
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


func is_mutation_form() -> bool:
	return not mutation_attr.is_empty()


# Evaluates a MUTATION-form condition against a pending StatMutation (the Arbitrator's
# interceptor match routes mutation-form conditions here, unit forms to evaluate()).
func evaluate_mutation(m: StatMutation) -> bool:
	if mutation_attr != "amount" or m == null:
		return false
	return _compare(m.amount)


# `owner` is the SIDE of the effect this condition belongs to (the container's owner) —
# required by the allegiance form, ignored by every other form. -1 = no side known
# (allegiance then fails closed: you can't compare against a side that isn't there).
func evaluate(card: CardInstance, owner: int = -1) -> bool:
	if is_mutation_form():
		return true   # not a unit predicate — routed to evaluate_mutation; vacuous here
	if not allegiance.is_empty():
		if owner < 0:
			return false
		match allegiance:
			"ally":  return card.owner == owner
			"enemy": return card.owner >= 0 and card.owner != owner
		return false
	if not status_id.is_empty():
		return (card.find_status(status_id) != null) == present
	if not composition.is_empty() and composition_counted:
		# The QUANTITY question, asked of the card's REAL composition: a grant makes a unit
		# be TREATED AS a component, which is not a claim about how MANY it is built from
		# (see the field note). Identity is the only lens that can answer "how much".
		return _compare(raw_component_count(card))
	if not composition.is_empty():
		# EFFECTIVE composition — the real one plus every live standing GRANT (see
		# LiveEffects.effective_composition). Conditions are the one consumer of virtual
		# components; identity reads (is_building/is_royalty, piece_count) stay raw.
		var has := false
		for id: String in composition:
			if LiveEffects.has_component(card, id):
				has = true
				break
		return has == present
	if not card_type.is_empty():
		var want_unit := card_type == "unit"
		return (card.data.card_type == CardData.CardType.UNIT) == want_unit
	if has_element_set:
		# Same lens as the composition form — a granted element must satisfy both alike.
		return LiveEffects.has_any_element(card) == has_element
	if untapped_set:
		return (not card.attack_exhausted) == untapped
	return _compare(card.get_attribute(attribute))


# How many of this condition's listed components the card is REALLY built from — the
# identity multiset (CardData.elements + chess_pieces, duplicates counted), never the
# grant-aware effective set. Occurrences of every listed id are SUMMED, so a two-id list
# asks "how many components drawn from this pool" rather than "how many of each".
func raw_component_count(card: CardInstance) -> int:
	if card == null or card.data == null:
		return 0
	var n := 0
	for id: String in card.data.elements:
		if composition.has(id):
			n += 1
	for id: String in card.data.chess_pieces:
		if composition.has(id):
			n += 1
	return n


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
