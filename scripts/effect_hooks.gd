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
	if ctx.ability == null or ctx.ability.material.is_empty():
		return []
	var material := CardData.get_card(ctx.ability.material)
	if material == null:
		return []
	if ctx.manual_target != null:
		if not CardData.can_combine(ctx.manual_target.data, material) \
				or ctx.manual_target.data.chess_pieces.has("king") \
				or ctx.manual_target.data.chess_pieces.has("rook"):
			return []
		ctx.manual_target.transform(CardData.combine(ctx.manual_target.data, material))
		if ctx.board_node != null:
			ctx.board_node.refresh()
		return [{"target": ctx.manual_target}]
	if ctx.manual_slot != null and ctx.board_node != null:
		var inst := CardInstance.from_data(material)
		inst.owner = 0
		Resolver.fill_health(inst)   # after owner is set, so run-wide unit bonuses fold in
		var out: Array = [{"target": inst}]
		out.append_array(ctx.board_node.spawn_player_card(inst, ctx.manual_slot.row, ctx.manual_slot.col))
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
