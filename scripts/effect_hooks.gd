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


# The hook for an id, or an invalid Callable if unknown (caller skips it).
static func get_hook(id: String) -> Callable:
	return _hooks.get(id, Callable())


# ── Hooks ────────────────────────────────────────────────────────────────────────────

# DEMO (data/upgrades/mysticism.json): when one of your units attacks, every other friendly
# unit gains +1 attack for the rest of the combat. Shows a hook reading the whole board and
# emitting multiple animatable results — logic a flat MODIFIER can't express.
static func _rallying_cry(ctx: EffectContext) -> Array:
	var results: Array = []
	for row: Array in ctx.player_board:
		for unit: CardInstance in row:
			if unit != null and unit != ctx.source and not unit.data.is_king:
				unit.apply_modifier("attack", 1)
				results.append({"target": unit, "attribute": "attack", "delta": 1})
	return results
