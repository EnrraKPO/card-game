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


# Whether standing effect `e` applies to `u` for `attr`.
# TARGETING REMOVED (targeting-cleanup demolition): standing MEMBERSHIP — "does this effect
# reach unit u?" — was targeting's second verb, and with no authority to ask, NO standing
# effect reaches ANYONE (the honest inert state: reaching everyone would leak self-buffs
# board-wide). What the demolished gate evaluated, for the rebuild:
#   · the SELF target kind reached the holder and nobody else;
#   · unit-stat payloads never landed on spell cards (cost being the one shared attribute);
#   · the legacy `filter` narrowing (kind / has_element) — authored data still carries it;
#   · the effect's conditions, evaluated against the CURRENT state with `holder` as identity
#     anchor and `owner` (the container's side) as allegiance anchor — STRATIFIED, via the
#     _in_condition latch: nested condition-bearing standing effects are invisible to gates,
#     or the fold would recurse into itself.
# NEEDS: the rebuilt authority answers membership as a cheap per-read predicate (this fold is
# hot — every get_attribute), and answers it with no combat context for the out-of-combat
# folds (deck screens, shop cost reads) — self/all+conditions need holder and owner alone.
static func _contributes(_e: Effect, _u: CardInstance, _holder: CardInstance, _owner: int, _attr: String) -> bool:
	return false


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
# TARGETING REMOVED (targeting-cleanup demolition): membership for grants mirrored the stat
# fold's — the SELF target kind reached the holder and nobody else; everything else reached
# whoever the conditions admitted. With no authority to ask, no grant reaches anyone.
# NEEDS, beyond the fold's membership predicate — the fixed-point subtleties the demolished
# walk encoded, which the rebuilt predicate must reproduce exactly:
#   · a grant's composition/has_element conditions read the WORKING set `comp` INLINE — never
#     the cache; that is the fixed point being computed;
#   · every other condition form (status/allegiance/card_type/attribute) reads current state
#     UNDER THE STRATIFICATION GUARD (_in_condition): attribute gates see base + baked +
#     unconditional live stats — grants never write stats, so no cycle back into the fold;
#   · intensity is irrelevant to a union payload (stacks don't multiply — only tracker
#     validity gates).
static func _grant_applies(_e: Effect, _u: CardInstance, _holder: CardInstance, _owner: int, _comp: Dictionary) -> bool:
	return false
