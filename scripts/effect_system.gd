class_name EffectSystem
extends RefCounted


# Returns an Array of {target, attribute, delta} for each application that
# used the parameterised path. Custom-apply results are not included since
# the system cannot know what changed.

# Apply a single effect with a pre-built context (used for spell casting and
# unit abilities with MANUAL targeting already resolved into context.manual_target).
static func apply_single(effect: Effect, source: CardInstance, context: EffectContext) -> Array:
	return _run_effect(effect, source, context)


# Fires the triggered effects a unit carries for an event, grouped BY CONTAINER so the dispatcher can
# cue each container before its effects: the card's own (native) effects form one group (status_id
# ""), and each active status forms its own group (its magnitudes scaled by stack count). Resolution
# itself is container-blind — the container id is carried only so presentation can glint the right
# badge; it never touches target resolution. Returns Array of { "status_id": String, "results": [] }
# (only groups that produced results).
static func trigger_grouped(event: GameEvent, source: CardInstance, context: EffectContext) -> Array:
	var groups: Array = []
	if source == null or source.data == null:
		return groups
	var native: Array = []
	for effect: Effect in source.data.effects:
		# Only event-driven kinds ride the trigger dispatch — MODIFIERs fold at read time,
		# INTERCEPTORs fire inside Resolver.submit; neither is an event reaction.
		if effect.kind != Effect.Kind.TRIGGERED and effect.kind != Effect.Kind.CUSTOM:
			continue
		# THE activation gate: the effect's injected resolver decides, from the event's
		# origin/destination and this holder, whether it fires (see TriggerResolver).
		if not effect.trigger_resolver().fires(event, source):
			continue
		native.append_array(_run_effect(effect, source, context, event))
	if not native.is_empty():
		groups.append({"status_id": "", "results": native})
	for grp: Dictionary in StatusEngine.triggered_groups(source, event.id):
		var sres: Array = []
		for effect: Effect in grp["effects"]:
			if not effect.trigger_resolver().fires(event, source):
				continue
			sres.append_array(_run_effect(effect, source, context, event, int(grp["stacks"])))
		if not sres.is_empty():
			groups.append({"status_id": grp["status_id"], "results": sres})
	return groups


# Flat results across all of a unit's containers — for callers that don't sequence per-container
# cues (card play, spells). Same resolution as trigger_grouped, one combined array.
static func trigger(event: GameEvent, source: CardInstance, context: EffectContext) -> Array:
	var out: Array = []
	for grp: Dictionary in trigger_grouped(event, source, context):
		out.append_array(grp["results"])
	return out


# Fires RUN-LEVEL triggered effects (upgrades/relics/heroes) for an event — the counterpart to
# trigger() for sources that aren't a card on the board. Resolved from the triggering card's
# perspective (context.source = the event's subject); fires only for player-side events so
# player upgrades react to the player's own units, not the enemy's. The perspective card also
# serves as the resolver's HOLDER, so relation conditions read relative to it (a legacy
# {"relation": "self"} gate passes trivially, preserving the old "global effects don't
# subject-filter" behavior).
static func trigger_global(event: GameEvent, context: EffectContext) -> Array:
	var results: Array = []
	if context.source == null or context.source.owner != 0:
		return results
	for effect: Effect in GameData.current_modifiers.triggered(event.id):
		if not effect.trigger_resolver().fires(event, context.source):
			continue
		results.append_array(_run_effect(effect, context.source, context, event))
	return results


# Run-level results GROUPED by their owning container (relic/upgrade), so the dispatcher can cue
# each owner — e.g. glint the relic's chip — before its effects' VFX. Returns Array of
# { "owner_kind": String, "owner_id": String, "results": [] } in firing order, only non-empty groups.
static func trigger_global_grouped(event: GameEvent, context: EffectContext) -> Array:
	var order: Array = []          # owner_ids in first-seen order
	var by_owner: Dictionary = {}  # owner_id -> group dict
	if context.source == null or context.source.owner != 0:
		return order
	for effect: Effect in GameData.current_modifiers.triggered(event.id):
		if not effect.trigger_resolver().fires(event, context.source):
			continue
		var res := _run_effect(effect, context.source, context, event)
		if res.is_empty():
			continue
		# Container identity is DISPATCH CONTEXT (the set knows who contributed what);
		# the effect itself is container-blind.
		var owner: Dictionary = GameData.current_modifiers.owner_of(effect)
		var oid := str(owner["id"])
		if not by_owner.has(oid):
			by_owner[oid] = {"owner_kind": str(owner["kind"]), "owner_id": oid, "results": []}
			order.append(oid)
		(by_owner[oid]["results"] as Array).append_array(res)
	var out: Array = []
	for key: String in order:
		out.append(by_owner[key])
	return out


# Runs one effect (TRIGGERED → resolve targets + apply; CUSTOM → invoke its code hook).
# `event` is the GameEvent that activated the effect (null for a transient use — a spell
# cast / ability activation), handed to the target resolver so participant targeting can
# reference the event's origin/destination. `amount_scale` multiplies stat/heal magnitudes
# (used to scale a stacked status's effects).
static func _run_effect(effect: Effect, source: CardInstance, context: EffectContext,
		event: GameEvent = null, amount_scale: int = 1) -> Array:
	# Probabilistic gate (the effect's `chance`): roll once; on a miss the effect doesn't fire at all.
	if effect.chance < 1.0 and randf() >= effect.chance:
		return []
	if effect.kind == Effect.Kind.CUSTOM:
		var hook := EffectHooks.get_hook(effect.custom_id)
		return hook.call(context) if hook.is_valid() else []
	# THE targeting socket: the effect's injected resolver returns the affected unit(s)
	# from the same shared context the trigger saw (see TargetResolver). Effects apply to
	# royalty (King/Queen) and lackeys alike; only the resolver's conditions filter.
	var results: Array = []
	for target: CardInstance in effect.targets_resolver().resolve(event, source, context):
		var r := _apply(effect, target, source, context, amount_scale)
		if not r.is_empty():
			results.append(r)
	return results


# ── Effect application ─────────────────────────────────────────────────────────

static func _apply(effect: Effect, target: CardInstance, source: CardInstance, context: EffectContext, amount_scale: int = 1) -> Dictionary:
	if effect.custom_apply.is_valid():
		effect.custom_apply.call(target)
		return {}
	# Generic "apply a status" operation: any effect can grant a status to each resolved target.
	if not effect.status_id.is_empty():
		target.apply_status(effect.status_id, effect.status_duration, effect.status_stacks, source)
		return {"target": target, "status_applied": effect.status_id}
	# Every branch returns {} for a no-op (nothing changed) and a non-empty result when something
	# happened — so "produced a result" == "the container did something", which drives the cue.
	var amount := effect.amount_int() * amount_scale
	if effect.attribute == "health":
		# Direct health change — a signed HEALTH mutation. The Resolver owns the form (negative
		# bypasses shield, e.g. poison; positive heals, clamped to max) and reports the delta
		# that actually landed. The shield-routed pipeline lives on "damage_taken".
		var out := Resolver.submit(StatMutation.make(target,
				StatMutation.stat_for_attribute(effect.attribute), amount, source))
		if out.delta == 0:
			return {}   # already full / 0 heal — nothing happened
		return {"target": target, "attribute": "health", "delta": out.delta}
	elif effect.attribute == "damage_taken":
		# The incoming-hit channel: attack-form damage — shield absorbs first, the remainder
		# wounds health. HOW it splits is the Resolver's knowledge, not ours.
		if amount <= 0:
			return {}
		Resolver.submit(StatMutation.make(target,
				StatMutation.stat_for_attribute(effect.attribute), amount, source))
		return {"target": target, "attribute": "health", "delta": -amount}
	else:
		if amount == 0:
			return {}
		Resolver.submit(StatMutation.make(target,
				StatMutation.stat_for_attribute(effect.attribute), amount, source))
		return {"target": target, "attribute": effect.attribute, "delta": amount}


# ── Condition evaluation ───────────────────────────────────────────────────────

# The same gate _resolve_targets applies, exposed for PRE-resolution eligibility checks —
# the spell-targeting UI (only eligible units light up / accept the drop) and the enemy AI's
# target picking, so an ineligible pick is impossible instead of a silent fizzle.
static func passes_conditions(conditions: Array, card: CardInstance, holder: CardInstance = null) -> bool:
	return _passes_conditions(conditions, card, holder)


static func _passes_conditions(conditions: Array, card: CardInstance, holder: CardInstance = null) -> bool:
	var owner := -1 if holder == null else holder.owner   # conditions are (unit, owner-side) predicates
	for cond: EffectCondition in conditions:
		if not cond.evaluate(card, owner):
			return false
	return true


# (Board flattening and the nearest-distance metric moved into TargetResolver — the
# targeting socket owns its own search primitives now.)
