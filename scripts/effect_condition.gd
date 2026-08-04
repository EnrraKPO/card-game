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
# VIABILITY-form condition — the one condition NOBODY AUTHORS. Every stat-targeting effect is
# given one at load (see Effect._install_viability), and it asks the question the payload itself
# implies: would this actually DO anything to that unit? A heal is not a heal to something at
# full health; a debuff is not a debuff to a stat already sitting on its floor. Both used to
# resolve, spend the card, play their numbers and change nothing.
#
# It rides in the ordinary conditions list on purpose. Everything that already consults
# conditions — target resolution, the spell-targeting UI's eligibility, the enemy AI's target
# picking, the autocast drop gate — inherits the rule with no second door to keep in sync, and
# the same list is what decides whether a spell has any legal play left at all.
#
# `implicit` keeps it out of to_dict: it was never in the authored file and must never appear in
# one (the effect schema round-trips byte-faithfully — see Effect.to_dict).
var op_attribute: String = ""
var op_amount: int = 0
# The stats whose value CANNOT go below a floor once resolution has spoken, and the read that
# answers where they stand. Reducing one that already sits on its floor writes a number nothing
# will ever look at:
#   attack     — StatMutation.damage floors a strike at 0, so a 0-attack unit swings for 0 either way
#   shield     — the authored name for the per-round BASE; current_shield floors at 0
#   strikes    — get_attribute floors it at 1; the basic attack cannot be stripped
# Deliberately NOT here: speed (turn order and the dodge/crit formulae read it signed, so pushing
# it further down keeps mattering), cost, and the dodge/crit bonuses (additive points on a
# derived chance, meaningful below zero).
const FLOORS := {
	"attack":     ["attack", 0],
	"shield":     ["max_shield", 0],
	"max_shield": ["max_shield", 0],
	"strikes":    ["strikes", 1],
}
# MUTATION-form condition: a predicate over a PENDING StatMutation rather than a unit —
# valid only on INTERCEPTOR effects (load-validated), evaluated by the Resolver's match
# via evaluate_mutation. "amount" is the one attribute today (e.g. {"mutation": "amount",
# "comparator": "gt", "value": 0} = "only heals" on a health intercept); the comparator
# machinery is shared with the attribute form.
var mutation_attr: String = ""
# Derived at load rather than authored (the viability form). Kept out of to_dict: it was never
# in the data file and must never appear in one.
var implicit := false


# Built only by Effect._install_viability — never by the authoring parser.
static func viability(attr: String, amount: int) -> EffectCondition:
	var c := EffectCondition.new()
	c.op_attribute = attr
	c.op_amount = amount
	c.implicit = true
	return c


func is_viability_form() -> bool:
	return not op_attribute.is_empty()


# Would applying this effect's payload to `card` change anything at all? The rules it encodes
# are the Resolver's own clamps, read back the other way round (see Resolver._apply_health /
# _dispatch_apply / StatMutation.damage) — so "no-op" here means exactly what "no-op" means
# once the mutation lands, and the two cannot drift apart into a card that lights up and then
# does nothing.
func _viable(card: CardInstance) -> bool:
	if op_amount == 0:
		return false                      # a zero payload is a no-op on anybody
	match op_attribute:
		"health":
			# Positive is a HEAL, clamped to max — nothing to give a unit that is whole.
			# Negative is a direct wound: it bypasses shield, has no floor, and can kill.
			if op_amount > 0:
				return card.current_health < card.get_attribute("max_health")
			return true
		"damage_taken":
			return op_amount > 0          # the attack-form channel; a non-positive hit deals nothing
	if op_amount > 0:
		return true                       # raising a stat always lands
	var floor_spec: Array = FLOORS.get(op_attribute, [])
	if floor_spec.is_empty():
		return true                       # unfloored: a reduction always means something
	return card.get_attribute(str(floor_spec[0])) > int(floor_spec[1])


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
	if implicit:
		# Derived at load from the effect's own payload — it has no authored spelling, and every
		# emit site drops it (see conditions_to_dicts). Reaching here means one forgot to.
		push_error("EffectCondition: an implicit condition has no authored form — %s" % [op_attribute])
		return {}
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


# Evaluates this condition against a SIDE participant (a CombatSide-targeted mutation
# passing through the interceptor match). Only the allegiance form can speak about a
# player; every other form is a unit predicate and fails CLOSED — a side has no stats,
# statuses, or composition to test.
func evaluate_side(side_owner: int, owner: int) -> bool:
	if allegiance.is_empty():
		return false
	if owner < 0:
		return false
	match allegiance:
		"ally":  return side_owner == owner
		"enemy": return side_owner >= 0 and side_owner != owner
	return false


# Evaluates a MUTATION-form condition against a pending StatMutation (the Resolver's
# interceptor match routes mutation-form conditions here, unit forms to evaluate()).
func evaluate_mutation(m: StatMutation) -> bool:
	if mutation_attr != "amount" or m == null:
		return false
	return _compare(m.amount)


func evaluate(card: CardInstance, owner: int = -1) -> bool:
	if is_mutation_form():
		return true   # not a unit predicate — routed to evaluate_mutation; vacuous here
	if is_viability_form():
		return card != null and _viable(card)
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
