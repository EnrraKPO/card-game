class_name LiveEffects
extends RefCounted

# THE standing-effect evaluator — the single read-time fold of every live ("while"-trigger)
# effect into CardInstance.get_attribute, replacing the three parallel per-container folds
# (StatusEngine.modifier_bonus, ModifierSet.card_bonus/GameData.card_bonus, and the ad-hoc
# Effect.matches_card gate). See EFFECT_SYSTEM_DESIGN.md §3.
#
# One question, asked identically for every source: "does standing effect e apply to
# unit u right now?" — the SELF target kind checks identity against the holder; every
# condition is a predicate over (tested unit, the effect's OWNER side). Contribution =
# amount × the effect's tracker intensity; a tracker is consulted via valid() on EVERY
# read (pull correctness — see EffectTracker).
#
# Enumerated sources, each supplying its holder (identity anchor, nullable) and its
# owner (allegiance anchor, always present — a status FORWARDS its carrier's owner):
#   • the unit's statuses     — holder = the carrier, owner = the carrier's side,
#                               tracker bound per StatusInstance
#   • the unit's own card     — holder = itself, owner = its side
#   • the run set             — relics/upgrades; holder = null, owner = the PLAYER.
#                               Legacy modifier-kind entries keep the historical implicit
#                               scope (player units only — the old GameData.card_bonus
#                               guard) as a parse-era shim; natively authored run effects
#                               say {"allegiance": "ally"} explicitly instead.
#
# LAYERED evaluation (EFFECT_SYSTEM_DESIGN.md stage 3 — "composition-as-derived"):
#   Layer 1 — composition GRANTS (Effect.grants) settle first, per unit, as a monotone
#     fixed point into a cached snapshot: effective_composition below. Priority is
#     structural — it derives from what an effect WRITES, never from authored numbers.
#   Layer 2 — the stat fold (bonus). Its composition/has_element conditions read the
#     SETTLED Layer-1 snapshot (a lookup, valid at any nesting depth, no recursion).
#
# Stratification (the documented rule replacing the old _in_modifier_condition hack),
# now scoped to Layer 2's ATTRIBUTE-form gates: while a standing effect's conditions are
# being evaluated, condition-BEARING standing STAT effects contribute nothing — a gate
# sees the unit as valued by base + baked + unconditional live effects. Deterministic,
# order-independent, and self-referential conditions ("+1 attack while attack >= 5")
# terminate. Composition truth is NOT stratified — it reads the settled snapshot.


static var _in_condition := false


# Summed live contribution to one attribute of one unit. Read-time only — nothing here
# writes, so expiry/removal needs no teardown (an invalid tracker is already inert).
static func bonus(inst: CardInstance, attr: String) -> int:
	if inst == null or inst.data == null:
		return 0
	var total := 0
	for si: StatusInstance in inst.statuses:
		for e: Effect in si.data.effects:
			if _contributes(e, inst, inst, inst.owner, attr):
				var t := si.tracker_for(e)
				if t.valid():
					total += e.amount_int() * t.intensity()
	for e: Effect in inst.data.effects:
		if _contributes(e, inst, inst, inst.owner, attr):
			total += e.amount_int()   # innate: the card itself is the (implicitly valid) host
	for e: Effect in GameData.current_modifiers.standing():
		# Parse-era shim: legacy modifier-kind run effects carry no allegiance condition;
		# their historical scope was "player combat units only". Dies with native authoring.
		if e.kind == Effect.Kind.MODIFIER and inst.owner != 0:
			continue
		if _contributes(e, inst, null, 0, attr):   # run container: no holder, owned by the player
			total += e.amount_int()
	return total


# Whether standing effect `e` applies to `u` for `attr` — targeting + conditions evaluated
# against the CURRENT state. `holder` is the identity anchor (null for run-scope);
# `owner` the allegiance anchor (the container's side — always present).
static func _contributes(e: Effect, u: CardInstance, holder: CardInstance, owner: int, attr: String) -> bool:
	if not e.is_standing():
		return false
	# (Composition grants pass the standing check but are naturally invisible here: their
	# standing_attribute() is "", which never equals a folded attr. They fold in Layer 1 —
	# effective_composition — never into the stat sum.)
	if e.standing_attribute() != attr:
		return false
	# The SELF target kind: the effect reaches the holder and nobody else.
	if e.targeting_policy == Effect.TargetingPolicy.SELF and u != holder:
		return false
	# Unit-stat payloads never land on spell cards; cost is the one shared attribute.
	if attr != "cost" and u.data.card_type == CardData.CardType.SPELL:
		return false
	# Legacy `filter` narrowing (kind / has_element) — kept for authored data; native
	# effects express the same through card_type / has_element conditions.
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
		if not c.evaluate(u, owner):
			ok = false
			break
	_in_condition = false
	return ok


# ── Effective composition (Layer 1) ─────────────────────────────────────────────────────
#
# A standing effect may GRANT component ids (Effect.grants): while live, its targets COUNT
# AS containing those components for condition resolution — the card's real composition
# (CardData.elements/chess_pieces, shared immutable identity) is never touched. Conditions
# read composition exclusively through has_component/has_any_element (see EffectCondition);
# identity reads (is_building/is_royalty, piece_count/element_count) deliberately stay raw.
#
# Per-unit FIXED POINT: a grant's own composition/has_element conditions read the WORKING
# set, so same-unit grant chains ("counts as rook while it counts as fire") settle in one
# computation, order-independently. Monotone by contract (union-only; negative composition
# predicates on grants are rejected at load — Effect._validate_grants), so the loop provably
# terminates: each pass either adds an id (bounded by the component vocabulary) or exits.
# Per-unit suffices because the condition grammar has no cross-unit predicate; if one ever
# lands, only this computation widens to a board-global pass — the API shape stays.
#
# SNAPSHOT-ON-CHANGE: the settled set is cached per instance and invalidated coarsely by
# every relevant writer — Resolver.submit (the single stat/status writer, which is what
# keeps this hook list short), status storage writes, StatusEngine.advance, ModifierSet
# growth, board owner assignment — then recomputed lazily on the next read. A deliberate
# deviation from §3's "deliberately uncached" rule; see EFFECT_SYSTEM_DESIGN.md stage 3.

static var _comp_cache: Dictionary = {}   # CardInstance -> Dictionary (component id -> true)
static var _computing: Dictionary = {}    # re-entrancy sentinel (belt-and-braces; see below)


# Drops every cached effective composition; the next read recomputes against current state.
static func invalidate_compositions() -> void:
	_comp_cache.clear()


# The settled effective composition of a unit: real composition ∪ every live grant.
# Degrades gracefully outside combat: no statuses, and run-set grants apply under the
# same semantics as every other standing read (allegiance gates fail closed on owner -1).
static func effective_composition(inst: CardInstance) -> Dictionary:
	if inst == null or inst.data == null:
		return {}
	if _comp_cache.has(inst):
		return _comp_cache[inst]
	if _computing.has(inst):
		# Unreachable by construction: composition conditions inside the fixed point read
		# the working set inline, and attribute gates run under _in_condition (grants never
		# write stats). If the invariant ever breaks, fail loud and serve the raw truth.
		push_error("LiveEffects: re-entrant effective_composition for '%s'" % inst.data.id)
		return _raw_composition(inst)
	_computing[inst] = true
	var comp := _raw_composition(inst)
	var changed := true
	while changed:
		changed = false
		for si: StatusInstance in inst.statuses:
			for e: Effect in si.data.effects:
				if _grant_applies(e, inst, inst, inst.owner, comp) and si.tracker_for(e).valid():
					changed = _union_grants(e, comp) or changed
		for e: Effect in inst.data.effects:
			if _grant_applies(e, inst, inst, inst.owner, comp):
				changed = _union_grants(e, comp) or changed
		for e: Effect in GameData.current_modifiers.standing():
			if _grant_applies(e, inst, null, 0, comp):   # run container: no holder, player-owned
				changed = _union_grants(e, comp) or changed
	_computing.erase(inst)
	_comp_cache[inst] = comp
	return comp


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


# Unions a grant's ids into the working set; true if anything new landed (fixed-point step).
static func _union_grants(e: Effect, comp: Dictionary) -> bool:
	var added := false
	for id: String in e.grants:
		if not comp.has(id):
			comp[id] = true
			added = true
	return added


# Whether grant effect `e` reaches `u` right now, judged against the WORKING set `comp`.
# Mirrors _contributes minus the stat-fold specifics: grants skip the spell exclusion
# (composition is identity for spells too), and their composition/has_element conditions
# read `comp` inline — never the cache; that is the fixed point being computed. Intensity
# is irrelevant to a union payload, so stacks don't multiply — only tracker validity gates.
static func _grant_applies(e: Effect, u: CardInstance, holder: CardInstance, owner: int, comp: Dictionary) -> bool:
	if not e.is_composition_grant():
		return false
	# The SELF target kind: the grant reaches the holder and nobody else.
	if e.targeting_policy == Effect.TargetingPolicy.SELF and u != holder:
		return false
	for c: EffectCondition in e.conditions:
		if not c.composition.is_empty():
			var has := false
			for id: String in c.composition:
				if comp.has(id):
					has = true
					break
			if has != c.present:
				return false
		elif c.has_element_set:
			var any := false
			for id: String in CardData.ELEMENT_IDS:
				if comp.has(id):
					any = true
					break
			if any != c.has_element:
				return false
		else:
			# Every other form (status/allegiance/card_type/attribute) reads current state.
			# Attribute gates run under the stratification guard: they see base + baked +
			# unconditional live stats — grants never write stats, so no cycle back here.
			var prev := _in_condition
			_in_condition = true
			var ok := c.evaluate(u, owner)
			_in_condition = prev
			if not ok:
				return false
	return true
