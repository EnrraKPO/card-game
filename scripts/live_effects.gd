class_name LiveEffects
extends RefCounted

# THE standing-effect evaluator — the single read-time fold of every live ("while"-trigger)
# effect into CardInstance.get_attribute, replacing the three parallel per-container folds
# (StatusEngine.modifier_bonus, ModifierSet.card_bonus/GameData.card_bonus, and the ad-hoc
# Effect.matches_card gate). See EFFECT_SYSTEM_DESIGN.md §3.
#
# One question, asked identically for every source: "does standing effect e, held by h,
# apply to unit u right now?" — answered by the shared condition vocabulary with the holder
# PRESENT (the missing holder is what silently killed relation-form conditions on the old
# modifier path). Contribution = amount × the effect's tracker intensity; a tracker is
# consulted via valid() on EVERY read (pull correctness — see EffectTracker).
#
# Enumerated sources (stage 1 — the unit's own containers plus the run set; cross-unit
# board sources ride the same call when a design needs them):
#   • the unit's statuses     — holder = the carrier, tracker bound per StatusInstance
#   • the unit's own card     — holder = itself (innate standing effects)
#   • the run set             — relics/upgrades; no unit holder. Legacy scope rule kept:
#                               run-wide card buffs reach PLAYER units only (owner 0), the
#                               exact guard GameData.card_bonus enforced.
#
# Stratification (the documented rule replacing the old _in_modifier_condition hack):
# while a standing effect's conditions are being evaluated, condition-BEARING standing
# effects contribute nothing — a gate sees the unit as valued by base + baked +
# unconditional live effects. Deterministic, order-independent, and self-referential
# conditions ("+1 attack while attack >= 5") terminate.


static var _in_condition := false


# Summed live contribution to one attribute of one unit. Read-time only — nothing here
# writes, so expiry/removal needs no teardown (an invalid tracker is already inert).
static func bonus(inst: CardInstance, attr: String) -> int:
	if inst == null or inst.data == null:
		return 0
	var total := 0
	for si: StatusInstance in inst.statuses:
		for e: Effect in si.data.effects:
			if _contributes(e, inst, inst, attr):
				var t := si.tracker_for(e)
				if t.valid():
					total += e.amount_int() * t.intensity()
	for e: Effect in inst.data.effects:
		if _contributes(e, inst, inst, attr):
			total += e.amount_int()   # innate: the card itself is the (implicitly valid) host
	if inst.owner == 0:
		for e: Effect in GameData.current_modifiers.standing():
			if _contributes(e, inst, null, attr):
				total += e.amount_int()
	return total


# Whether standing effect `e` (held by `holder`, null for run-scope) applies to `u` for
# `attr` — targeting + conditions evaluated against the CURRENT state, holder supplied.
static func _contributes(e: Effect, u: CardInstance, holder: CardInstance, attr: String) -> bool:
	if not e.is_standing():
		return false
	if e.standing_attribute() != attr:
		return false
	# Unit-stat payloads never land on spell cards; cost is the one shared attribute.
	if attr != "cost" and u.data.card_type == CardData.CardType.SPELL:
		return false
	# Legacy `filter` narrowing (kind / has_element) — kept for authored data; native
	# effects express the same through conditions.
	match str(e.filter.get("kind", "")):
		"unit":
			if u.data.card_type != CardData.CardType.UNIT:
				return false
		"spell":
			if u.data.card_type != CardData.CardType.SPELL:
				return false
	if bool(e.filter.get("has_element", false)) and u.data.elements.is_empty():
		return false
	if e.conditions.is_empty():
		return true
	# Stratified: nested condition-bearing standing effects are invisible to gates.
	if _in_condition:
		return false
	_in_condition = true
	var ok := true
	for c: EffectCondition in e.conditions:
		if not c.evaluate(u, holder):
			ok = false
			break
	_in_condition = false
	return ok
