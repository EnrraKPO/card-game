class_name EffectSystem
extends RefCounted


# Returns an Array of {target, attribute, delta} for each application that
# used the parameterised path. Custom-apply results are not included since
# the system cannot know what changed.

# Apply a single effect with a pre-built context (used for spell casting and
# unit abilities with MANUAL targeting already resolved into context.manual_target).
static func apply_single(effect: Effect, source: CardInstance, context: EffectContext) -> Array:
	var results: Array = []
	var targets := _resolve_targets(effect, source, context)
	for target: CardInstance in targets:
		var r := _apply(effect, target)
		if not r.is_empty():
			results.append(r)
	return results


static func trigger(event: Effect.Trigger, source: CardInstance, context: EffectContext) -> Array:
	var results: Array = []
	if source == null or source.data == null:
		return results
	for effect: Effect in source.data.effects:
		if effect.trigger != event:
			continue
		var targets := _resolve_targets(effect, source, context)
		for target: CardInstance in targets:
			var r := _apply(effect, target)
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

	return candidates.filter(
		func(c: CardInstance) -> bool: return _passes_conditions(effect.conditions, c)
	)


# ── Effect application ─────────────────────────────────────────────────────────

static func _apply(effect: Effect, target: CardInstance) -> Dictionary:
	if effect.custom_apply.is_valid():
		effect.custom_apply.call(target)
		return {}
	if effect.attribute == "health":
		if effect.amount < 0:
			target.take_damage(-effect.amount)
			return {"target": target, "attribute": "health", "delta": effect.amount}
		else:
			var max_hp := target.get_attribute("max_health")
			var healed := mini(effect.amount, max_hp - target.current_health)
			target.current_health += healed
			return {"target": target, "attribute": "health", "delta": healed}
	else:
		target.apply_modifier(effect.attribute, effect.amount)
		return {"target": target, "attribute": effect.attribute, "delta": effect.amount}


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
