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
static func trigger_grouped(event: Effect.Trigger, source: CardInstance, context: EffectContext) -> Array:
	var groups: Array = []
	if source == null or source.data == null:
		return groups
	var native: Array = []
	for effect: Effect in source.data.effects:
		if effect.kind == Effect.Kind.MODIFIER or effect.trigger != event:
			continue
		if not _subject_matches(effect, context.subject, source):
			continue
		native.append_array(_run_effect(effect, source, context))
	if not native.is_empty():
		groups.append({"status_id": "", "results": native})
	for grp: Dictionary in StatusEngine.triggered_groups(source, event):
		var sres: Array = []
		for effect: Effect in grp["effects"]:
			if not _subject_matches(effect, context.subject, source):
				continue
			sres.append_array(_run_effect(effect, source, context, int(grp["stacks"])))
		if not sres.is_empty():
			groups.append({"status_id": grp["status_id"], "results": sres})
	return groups


# Flat results across all of a unit's containers — for callers that don't sequence per-container
# cues (card play, spells). Same resolution as trigger_grouped, one combined array.
static func trigger(event: Effect.Trigger, source: CardInstance, context: EffectContext) -> Array:
	var out: Array = []
	for grp: Dictionary in trigger_grouped(event, source, context):
		out.append_array(grp["results"])
	return out


# Whether an event-driven effect reacts to THIS event, given the event's subject and the effect's
# HOLDER. Two gates: the relationship of the subject to the holder, then (if the effect names any)
# the subject's elements. Both must pass.
static func _subject_matches(effect: Effect, subject: CardInstance, holder: CardInstance) -> bool:
	if not _subject_relationship_ok(effect.subject_filter, subject, holder):
		return false
	if not effect.subject_elements.is_empty():
		if subject == null or subject.data == null:
			return false
		var has := false
		for el: String in effect.subject_elements:
			if subject.data.elements.has(el):
				has = true
				break
		if not has:
			return false
	return true


# The relationship gate: how the subject must relate to the holder. SELF (the default) also passes
# when there is no subject (a phase event like turn-end), meaning "the holder reacts for itself".
static func _subject_relationship_ok(filter: Effect.SubjectFilter, subject: CardInstance, holder: CardInstance) -> bool:
	match filter:
		Effect.SubjectFilter.SELF:  return subject == null or subject == holder
		Effect.SubjectFilter.ALLY:  return subject != null and subject.owner == holder.owner
		Effect.SubjectFilter.ENEMY: return subject != null and subject.owner != holder.owner
		Effect.SubjectFilter.ANY:   return true
	return false


# Fires RUN-LEVEL triggered effects (upgrades/relics/heroes) for an event — the counterpart to
# trigger() for sources that aren't a card on the board. Resolved from the triggering card's
# perspective (context.source); fires only for player-side events so player upgrades react to
# the player's own units, not the enemy's.
static func trigger_global(event: Effect.Trigger, context: EffectContext) -> Array:
	var results: Array = []
	if context.source == null or context.source.owner != 0:
		return results
	for effect: Effect in GameData.current_modifiers.triggered(event):
		if not _subject_matches(effect, context.subject, context.source):
			continue
		results.append_array(_run_effect(effect, context.source, context))
	return results


# Run-level results GROUPED by their owning container (relic/upgrade), so the dispatcher can cue
# each owner — e.g. glint the relic's chip — before its effects' VFX. Returns Array of
# { "owner_kind": String, "owner_id": String, "results": [] } in firing order, only non-empty groups.
static func trigger_global_grouped(event: Effect.Trigger, context: EffectContext) -> Array:
	var order: Array = []          # owner_ids in first-seen order
	var by_owner: Dictionary = {}  # owner_id -> group dict
	if context.source == null or context.source.owner != 0:
		return order
	for effect: Effect in GameData.current_modifiers.triggered(event):
		if not _subject_matches(effect, context.subject, context.source):
			continue
		var res := _run_effect(effect, context.source, context)
		if res.is_empty():
			continue
		if not by_owner.has(effect.owner_id):
			by_owner[effect.owner_id] = {"owner_kind": effect.owner_kind, "owner_id": effect.owner_id, "results": []}
			order.append(effect.owner_id)
		(by_owner[effect.owner_id]["results"] as Array).append_array(res)
	var out: Array = []
	for key: String in order:
		out.append(by_owner[key])
	return out


# Runs one effect (TRIGGERED → resolve targets + apply; CUSTOM → invoke its code hook).
# `amount_scale` multiplies stat/heal magnitudes (used to scale a stacked status's effects).
static func _run_effect(effect: Effect, source: CardInstance, context: EffectContext, amount_scale: int = 1) -> Array:
	# Probabilistic gate (the effect's `chance`): roll once; on a miss the effect doesn't fire at all.
	if effect.chance < 1.0 and randf() >= effect.chance:
		return []
	if effect.kind == Effect.Kind.CUSTOM:
		var hook := EffectHooks.get_hook(effect.custom_id)
		return hook.call(context) if hook.is_valid() else []
	var results: Array = []
	for target: CardInstance in _resolve_targets(effect, source, context):
		var r := _apply(effect, target, source, amount_scale)
		if not r.is_empty():
			results.append(r)
	return results


# ── Target resolution ──────────────────────────────────────────────────────────

static func _resolve_targets(effect: Effect, source: CardInstance, context: EffectContext) -> Array:
	var own_board := context.player_board if source.owner == 0 else context.enemy_board
	var opp_board := context.enemy_board  if source.owner == 0 else context.player_board

	var candidates: Array = []
	match effect.targeting_policy:
		Effect.TargetingPolicy.SELF:
			candidates = [source]
		Effect.TargetingPolicy.SINGLE_NEAREST:
			var nearest := _find_nearest(source, opp_board)
			if nearest:
				candidates = [nearest]
		Effect.TargetingPolicy.SINGLE_RANDOM:
			var pool := _flatten(opp_board)
			if not pool.is_empty():
				candidates = [pool[randi() % pool.size()]]
		Effect.TargetingPolicy.ALL_ENEMIES:
			candidates = _flatten(opp_board)
		Effect.TargetingPolicy.ALL_ALLIES:
			candidates = _flatten(own_board)
		Effect.TargetingPolicy.ALL:
			candidates = _flatten(own_board) + _flatten(opp_board)
		Effect.TargetingPolicy.MANUAL:
			if context.manual_target != null:
				candidates = [context.manual_target]
		Effect.TargetingPolicy.ATTACK_TARGET:
			if context.attack_target != null:
				candidates = [context.attack_target]
		Effect.TargetingPolicy.SUBJECT:
			if context.subject != null:
				candidates = [context.subject]
		Effect.TargetingPolicy.ATTACKER:
			if context.attacker != null:
				candidates = [context.attacker]

	# Effects apply to royalty (King/Queen) and lackeys alike; only the per-effect conditions filter.
	return candidates.filter(func(c: CardInstance) -> bool: return _passes_conditions(effect.conditions, c))


# ── Effect application ─────────────────────────────────────────────────────────

static func _apply(effect: Effect, target: CardInstance, source: CardInstance, amount_scale: int = 1) -> Dictionary:
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
		# Direct health change — straight to HP. Damage (negative) ignores shield (e.g. poison);
		# a heal (positive) is clamped to max. The shield pipeline lives on "damage_taken".
		if amount < 0:
			target.current_health += amount
			return {"target": target, "attribute": "health", "delta": amount}
		var max_hp := target.get_attribute("max_health")
		var healed := mini(amount, max_hp - target.current_health)
		if healed == 0:
			return {}   # already full / 0 heal — nothing happened
		target.current_health += healed
		return {"target": target, "attribute": "health", "delta": healed}
	elif effect.attribute == "damage_taken":
		# The incoming-hit channel: a positive amount is damage the shield absorbs first, the
		# remainder wounding health — the same resolution an attack goes through.
		if amount <= 0:
			return {}
		target.take_damage(amount)
		return {"target": target, "attribute": "health", "delta": -amount}
	elif effect.attribute == "negate_attack":
		# Queue one more negated attack on the target (its next strike deals 0). That's the whole job;
		# the pip cue and the "Miss" follow on their own. Returns a non-empty result so the cue fires.
		target.negate_next_attacks += 1
		return {"target": target}
	else:
		if amount == 0:
			return {}
		target.apply_modifier(effect.attribute, amount)
		return {"target": target, "attribute": effect.attribute, "delta": amount}


# ── Condition evaluation ───────────────────────────────────────────────────────

static func _passes_conditions(conditions: Array, card: CardInstance) -> bool:
	for cond: EffectCondition in conditions:
		if not cond.evaluate(card):
			return false
	return true


# ── Board utilities ────────────────────────────────────────────────────────────

static func _flatten(board: Array) -> Array:
	var result: Array = []
	for row in board:
		for cell in row:
			if cell != null:
				result.append(cell)
	return result


static func _find_nearest(source: CardInstance, target_board: Array) -> CardInstance:
	var best: CardInstance = null
	var best_dist := 999
	for r in target_board.size():
		for c in target_board[r].size():
			var candidate: CardInstance = target_board[r][c]
			if candidate == null:
				continue
			var dist: int = abs(source.row + r - (BoardData.ROWS - 1))
			if source.owner == 0:
				dist += BoardData.COLS + c - source.col
			else:
				dist += BoardData.COLS + source.col - c
			if dist < best_dist:
				best_dist = dist
				best = candidate
	return best
