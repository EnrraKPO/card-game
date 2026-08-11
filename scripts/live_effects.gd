class_name LiveEffects
extends RefCounted

# The read-time surface of the PASSIVE system (TARGETING_DESIGN.md §6): the standing-effect
# fold into CardInstance.get_attribute (bonus) and the effective-composition read the
# condition grammar consumes (has_component / has_any_element).
#
# RAZED to the surface (targeting-cleanup, 2026-08-11): the old Effect-union fold, its
# trackers, and the grant fixed-point walk were deleted with the effect layer — nothing
# authored exists to fold, so 0 / the raw composition IS the current truth. This file is
# the rebuilt PassiveEffect system's home; its NEEDS are the design's §6:
#   · bonus — continuous stat contributions from PassiveEffects on statuses, the card
#     itself, and the run set (holder = identity anchor, owner side = allegiance anchor),
#     cheap per read, answerable OUT of combat (deck screens, shop costs);
#   · Layer 1 — composition GRANTS settle as a per-unit monotone fixed point, derived
#     fresh on every read (union-only; the working set is read inline during the walk);
#   · Layer 2 — the stat fold's attribute-form gates run under the stratification guard
#     (_in_condition): while a gate is being evaluated, condition-bearing standing STAT
#     contributions are invisible, so self-referential gates terminate.
#
# NOTHING IS CACHED — user ruling 2026-08-11 ("composition caching is unsanctioned and
# thus void"): any live effect may affect any other, so any stat alteration invalidates
# everything; a sound cache is impossible fine-grained and worthless coarse. Every read
# derives from current containers and discards. Staleness is impossible by construction,
# and no lifetime/validity object (the old EffectTracker) exists: an expired container is
# simply not encountered by the walk.

static var _in_condition := false


# Summed live contribution to one attribute of one unit. Read-time only — nothing here
# writes, so expiry/removal needs no teardown.
static func bonus(inst: CardInstance, _attr: String) -> int:
	if inst == null or inst.data == null:
		return 0
	return 0   # no passive system exists yet — see the header NEEDS


# ── Effective composition (Layer 1) ─────────────────────────────────────────────────────
#
# Conditions read composition exclusively through has_component/has_any_element; identity
# reads (is_building/is_royalty, piece_count/element_count) deliberately stay raw.
# Derived fresh on every read (see the header ruling) — writers owe no invalidation call.


# The settled effective composition of a unit: real composition ∪ every live grant.
# With no passive system, that is the raw composition — the honest current truth.
static func effective_composition(inst: CardInstance) -> Dictionary:
	if inst == null or inst.data == null:
		return {}
	return _raw_composition(inst)


# Whether the unit's effective composition contains a component id — THE composition truth
# every condition reads (EffectCondition's composition form).
static func has_component(inst: CardInstance, component_id: String) -> bool:
	return effective_composition(inst).has(component_id)


# Whether the unit's effective composition contains any element (the has_element form).
static func has_any_element(inst: CardInstance) -> bool:
	var comp := effective_composition(inst)
	for id: String in CardData.ELEMENT_IDS:
		if comp.has(id):
			return true
	return false


static func _raw_composition(inst: CardInstance) -> Dictionary:
	var comp: Dictionary = {}
	for id: String in inst.data.elements:
		comp[id] = true
	for id: String in inst.data.chess_pieces:
		comp[id] = true
	return comp
