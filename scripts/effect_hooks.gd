class_name EffectHooks
extends RefCounted

# Code registry for CUSTOM effects (Effect.Kind.CUSTOM). A custom effect names a hook by id;
# the hook is arbitrary GDScript that the schema can't express, run with the live combat
# context. Keeping them in an id-keyed registry (rather than inline callables in data) means a
# CUSTOM effect stays serialisable/authorable — JSON references the id, the code lives here.
#
# A hook is `func(ctx: EffectContext) -> Array`, returning result dicts
# ({target, attribute, delta}) so combat can animate them, exactly like the parameterised path.

static var _hooks: Dictionary = {}


static func _static_init() -> void:
	_hooks["rallying_cry"] = _rallying_cry
	_hooks["deliver_material"] = _deliver_material


# The hook for an id, or an invalid Callable if unknown (caller skips it).
static func get_hook(id: String) -> Callable:
	return _hooks.get(id, Callable())


# ── Hooks ────────────────────────────────────────────────────────────────────────────

# Material delivery (the "X Material" activated abilities — see AbilityData): the ability's
# `material` field names what it delivers, read off the activation context. An occupied pick
# MERGES: the target's composition combines with the material (CardData.combine) and the unit
# transforms in place, wounds carried. An EMPTY pick SPAWNS the material's unit card there.
# Eligibility (own side, merge caps, no kings, no rooks/buildings) was already enforced at
# pick time by the MANUAL_SLOT targeting flow; the guards here are backstops. The enemy AI
# never routes here — its v1 policy always spawns, handled in combat's GENERATE branch.
static func _deliver_material(ctx: EffectContext) -> Array:
	# Material key: the per-EFFECT override (ctx.effect.material) wins, else the ability's own
	# `material`. Lets one ability deliver several DIFFERENT materials from separate effects
	# (e.g. an elemental Conscription: deliver a pawn, then an element).
	var mat_key := ""
	if ctx.effect != null and not ctx.effect.material.is_empty():
		mat_key = ctx.effect.material
	elif ctx.ability != null:
		mat_key = ctx.ability.material
	if mat_key.is_empty():
		return []
	var material := CardData.get_card(mat_key)
	if material == null:
		return []
	# The effective MERGE target: an explicitly-picked unit, OR the current occupant of a picked
	# slot. That occupant may have been spawned by a PRIOR effect in this same activation — which
	# is what lets a two-part delivery ("a pawn, then a fire") build a fire_pawn on an EMPTY slot:
	# the first effect spawns the pawn, the second finds it here and merges the fire onto it.
	var target: CardInstance = ctx.manual_target
	if target == null and ctx.manual_row >= 0 and ctx.world != null:
		target = ctx.world.unit_at(0, ctx.manual_row, ctx.manual_col)
	if target != null:                                    # ── MERGE onto the (possibly just-spawned) unit
		if not CardData.can_combine(target.data, material) \
				or target.data.chess_pieces.has("king") \
				or target.data.chess_pieces.has("rook"):
			return []
		target.transform(CardData.combine(target.data, material))
		# No board refresh here: the result rides back to the animator, whose play_results
		# snaps the transformed card's printed stats itself.
		return [{"target": target}]
	if ctx.manual_row >= 0 and ctx.world != null:   # ── SPAWN on the empty slot
		if material.chess_pieces.is_empty():
			return []   # never spawn a piece-less (element-only) material as a board unit
		var inst := CardInstance.from_data(material)
		inst.owner = 0
		Resolver.fill_health(inst)   # after owner is set, so run-wide unit bonuses fold in
		var out: Array = [{"target": inst}]
		ctx.world.spawn_unit(inst, ctx.manual_row, ctx.manual_col, 0)
		out.append_array(ctx.world.play_dispatch(inst))
		ctx.world.cleanup_deaths()
		return out
	return []


# DEMO (data/upgrades/mysticism.json): when one of your units attacks, every other friendly
# unit gains +1 attack for the rest of the combat. Shows a hook reading the whole board and
# emitting multiple animatable results — logic a flat MODIFIER can't express.
static func _rallying_cry(ctx: EffectContext) -> Array:
	var results: Array = []
	for row: Array in ctx.player_board:
		for unit: CardInstance in row:
			if unit != null and unit != ctx.source and not unit.data.is_king:
				Resolver.submit(StatMutation.make(unit, StatMutation.ATTACK, 1, ctx.source))
				results.append({"target": unit, "attribute": "attack", "delta": 1})
	return results
