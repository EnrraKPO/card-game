class_name SimEffects
extends RefCounted

# The enemy engine's SIMULATED effect application: applies an ability's / spell's ON_PLAY
# effects to a BoardState copy so candidates can be scored (design decision 17 — apply the
# effect, look at what the world became).
#
# ⚠ THIS IS NOT THE RULES EXTRACTION (design Part 5, step 0). It is a deliberately small
# INTERPRETER over the real parsed Effect objects — the same AbilityData/CardData.effects
# the live game resolves — kept honest two ways:
#   1. it reads authored data, never a re-authored copy, so content edits reach it;
#   2. can_simulate() REFUSES anything whose semantics it does not reproduce, and the
#      candidate generators drop those plays entirely — the engine never plays what it
#      cannot evaluate (conservative fail-closed, the guard rail of decision 18).
# When the real presentation-free rules layer lands, it replaces the body of apply_cast
# and can_simulate widens toward "everything"; the seam (and its callers) stay put.
#
# Semantics mirrored from the Resolver (resolver.gd — the single writer):
#   · a direct `health` effect wounds THROUGH the shield (poison-style; attack damage is
#     the thing shields stop, and the sim never runs attacks) and heals clamp to max;
#   · a `shield` effect moves the pool, floored at 0.
#
# KNOWN DIVERGENCE (accepted for this slice, surface in the Gym): a unit the simulation
# kills is removed WITHOUT firing its death triggers — a candidate that kills an
# on-death unit is scored slightly wrong. The rules extraction is the fix, not a patch here.

# The effect payloads + target shapes this interpreter reproduces faithfully.
const SUPPORTED_ATTRS: Array[String] = ["health", "shield"]
const SUPPORTED_POLICIES: Array[int] = [
	Effect.TargetingPolicy.SELF,
	Effect.TargetingPolicy.MANUAL,
	Effect.TargetingPolicy.ALL_ALLIES,
	Effect.TargetingPolicy.ALL_ENEMIES,
	Effect.TargetingPolicy.ALL,
]


# Whether a cast of these effects can be simulated faithfully: every ON_PLAY effect must be
# reproducible (they all fire together on cast — a half-simulated cast would score a board
# that can never exist), and at least one must exist (a castable no-op isn't a candidate).
static func can_simulate_cast(effects: Array) -> bool:
	var any := false
	for e: Effect in effects:
		if e.trigger != Effect.Trigger.ON_PLAY:
			continue   # never fires at cast time — irrelevant to the simulation
		if not _supported(e):
			return false
		any = true
	return any


static func _supported(e: Effect) -> bool:
	if e.kind != Effect.Kind.TRIGGERED:
		return false          # custom hooks / interceptors: arbitrary code, no sim story yet
	if e.chance < 1.0:
		return false          # probabilistic: the sim would have to guess the roll
	if not e.conditions.is_empty():
		return false          # per-target eligibility gates: not evaluated sim-side yet
	if not e.status_id.is_empty() or not e.spawn_id.is_empty() or not e.grants.is_empty():
		return false          # statuses / spawns / grants: stateful payloads the sim lacks
	if not SUPPORTED_ATTRS.has(e.attribute):
		return false
	return SUPPORTED_POLICIES.has(e.targeting_policy)


# Whether any of the cast's effects needs a manually picked target — then the candidate
# generators enumerate one candidate per possible target ("tested against EVERY possible
# target", decision 17).
static func needs_manual(effects: Array) -> bool:
	for e: Effect in effects:
		if e.trigger == Effect.Trigger.ON_PLAY \
				and e.targeting_policy == Effect.TargetingPolicy.MANUAL:
			return true
	return false


# Applies a cast's ON_PLAY effects to `state` IN PLACE (callers pass a copy — this is the
# body of the apply seam, reached only through CandidateApply). `caster` is the fielded
# holder for an ability, null for a hand spell; `target` the manually picked unit, null
# when nothing manual. Dead units are swept after all effects land, mirroring the live
# cleanup order (cleanup_effect_deaths after the cast resolves).
static func apply_cast(state: BoardState, effects: Array, caster_side: int,
		caster: BoardState.UnitState, target: BoardState.UnitState) -> void:
	for e: Effect in effects:
		if e.trigger != Effect.Trigger.ON_PLAY:
			continue
		for u: BoardState.UnitState in _resolve_targets(state, e, caster_side, caster, target):
			_apply_payload(u, e)
	_sweep_dead(state)


static func _resolve_targets(state: BoardState, e: Effect, caster_side: int,
		caster: BoardState.UnitState, target: BoardState.UnitState) -> Array:
	match e.targeting_policy:
		Effect.TargetingPolicy.SELF:
			return [caster] if caster != null else []
		Effect.TargetingPolicy.MANUAL:
			return [target] if target != null else []
		Effect.TargetingPolicy.ALL_ALLIES:
			return state.units(caster_side)
		Effect.TargetingPolicy.ALL_ENEMIES:
			return state.units(1 - caster_side)
		Effect.TargetingPolicy.ALL:
			return state.units(0) + state.units(1)
	return []


static func _apply_payload(u: BoardState.UnitState, e: Effect) -> void:
	var amt := e.amount_int()
	match e.attribute:
		"health":
			if amt >= 0:
				u.health = mini(u.health + amt, u.max_health)   # heals clamp to effective max
			else:
				u.health += amt   # direct wounds pierce the shield (Resolver: poison-style)
		"shield":
			u.shield = maxi(0, u.shield + amt)


static func _sweep_dead(state: BoardState) -> void:
	for side in 2:
		var grid := state.grid_of(side)
		for r in BoardData.ROWS:
			for c in BoardData.COLS:
				var u: BoardState.UnitState = grid[r][c]
				if u != null and u.health <= 0:
					grid[r][c] = null   # death triggers NOT fired — see the header divergence
