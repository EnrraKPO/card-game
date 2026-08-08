class_name EnemyAI
extends RefCounted

# The CPU's action vocabulary. decide_actions() returns an ordered list of these
# for the orchestrator to execute; combat._execute_enemy_action dispatches on type.
#   { "type": Action.PLACE,    "inst": CardInstance, "row": int, "col": int }
#   { "type": Action.CAST,     "inst": CardInstance, "target": CardInstance|null }
#   { "type": Action.GENERATE, "unit": CardInstance, "ability": AbilityData, "row": int, "col": int }      — material spawn
#   { "type": Action.GENERATE, "unit": CardInstance, "ability": AbilityData, "target": CardInstance|null } — targeted ability
#   { "type": Action.MOVE,     "inst": CardInstance, "row": int, "col": int }
enum Action { PLACE, MOVE, CAST, GENERATE }

# Registry keyed by the "ai" string in encounter template JSON. Add a new
# match arm here (and a matching EnemyAI subclass) to give an encounter a
# distinct CPU behaviour — no other file needs to change.
static func from_key(key: String) -> EnemyAI:
	match key:
		"default", "":
			return EnemyAI.new()
		_:
			push_error("EnemyAI: unknown ai key '%s', falling back to default" % key)
			return EnemyAI.new()


# Plans a whole CPU turn. Mana is spent greedily and the planner tracks remaining
# mana plus a local copy of slot occupancy, so every action it emits is still legal
# when executed in order. Override in a subclass for distinct encounter behaviour.
#
# Priorities (basic tactics): spend spells on good targets, deploy units to the
# front, advance an idle backline unit, and use leftover mana on building tokens.
func decide_actions(hand: Array, board: CombatBoard, mana: int) -> Array:
	var actions: Array = []
	var occ := _occupancy(board.enemy_grid)
	var used: Dictionary = {}  # CardInstance (hand card) -> true once spent
	var remaining := mana

	remaining = _plan_spells(hand, board, used, remaining, actions)
	remaining = _plan_placements(hand, occ, used, remaining, actions)
	_plan_advance(board, occ, actions)
	_plan_generation(board, occ, remaining, actions)
	return actions


# ── Spells ───────────────────────────────────────────────────────────────────────

func _plan_spells(hand: Array, board: CombatBoard, used: Dictionary, remaining: int, actions: Array) -> int:
	for inst: CardInstance in hand:
		if used.has(inst) or not inst.is_spell:
			continue
		if inst.data.cost > remaining or not _has_on_play(inst):
			continue
		var target: CardInstance = null
		if _needs_manual(inst):
			target = _pick_spell_target(inst, board)
			if target == null:
				continue  # nothing worth hitting — hold the spell
		actions.append({ "type": Action.CAST, "inst": inst, "target": target })
		used[inst] = true
		remaining -= inst.data.cost
	return remaining


# Offensive spells hit the player; supportive ones favour our own units. Effects apply to royalty
# and lackeys alike, so any unit on the relevant side is a valid pick.
func _pick_spell_target(inst: CardInstance, board: CombatBoard) -> CardInstance:
	if _is_offensive(inst):
		var pool := _units(board.player_grid)
		var dmg := _health_damage(inst)
		if dmg > 0:
			# Prefer a unit this spell can outright kill (the scariest such unit).
			var killable := pool.filter(func(u: CardInstance) -> bool: return u.current_health <= dmg)
			if not killable.is_empty():
				return _highest_attack(killable)
		if not pool.is_empty():
			return _highest_attack(pool)
		return null
	else:
		var allies := _units(board.enemy_grid)
		if allies.is_empty():
			return null
		if _is_heal(inst):
			return _lowest_health(allies)
		return _highest_attack(allies)


# ── Placements ─────────────────────────────────────────────────────────────────────

func _plan_placements(hand: Array, occ: Array, used: Dictionary, remaining: int, actions: Array) -> int:
	var units := hand.filter(func(i: CardInstance) -> bool:
		return not used.has(i) and not i.is_spell and not i.data.is_king)
	# Costliest first so big mana turns deploy threats; cheaper cards fill the rest.
	units.sort_custom(func(a: CardInstance, b: CardInstance) -> bool: return a.data.cost > b.data.cost)
	for inst: CardInstance in units:
		if inst.data.cost > remaining:
			continue
		var slot := _take_front_slot(occ)
		if slot.is_empty():
			break  # board full
		actions.append({ "type": Action.PLACE, "inst": inst, "row": slot[0], "col": slot[1] })
		used[inst] = true
		remaining -= inst.data.cost
	return remaining


# Pulls one idle backline unit forward into the frontmost empty slot, so the army
# visibly advances instead of sitting still. One move per turn keeps it legible.
func _plan_advance(board: CombatBoard, occ: Array, actions: Array) -> void:
	var slot := _take_front_slot(occ)
	if slot.is_empty():
		return
	var dest_col: int = slot[1]
	var best: CardInstance = null
	var best_col := -1
	for inst: CardInstance in _units(board.enemy_grid):
		if inst.data.is_king or inst.data.is_building():
			continue  # buildings are rooted
		var loc := BoardFacade.location_of(board.world, inst)
		if loc != null and loc.col > dest_col and loc.col > best_col:
			best = inst  # the furthest-back mover ahead of the empty slot
			best_col = loc.col
	if best != null:
		actions.append({ "type": Action.MOVE, "inst": best, "row": slot[0], "col": dest_col })


# ── Ability activation (uses leftover mana) ───────────────────────────────────────

# Activates units' abilities with the leftover mana. V1 policy per ability: a MATERIAL ability
# always resolves as its SPAWN half on a planned slot (functionally the old unit generation;
# merge smarts later); any other manually-targeted ability needs an eligible own-side target
# picked here — none eligible = hold it (don't waste the tap on a guaranteed fizzle). A
# tap-costed activation ends that unit's planning for the turn.
func _plan_generation(board: CombatBoard, occ: Array, remaining: int, actions: Array) -> void:
	for inst: CardInstance in _units(board.enemy_grid):
		if inst.attack_exhausted:
			continue
		for ab: AbilityData in inst.ability_list():
			if ab.mana > remaining:
				continue
			if not ab.material.is_empty():
				var slot := _take_front_slot(occ)
				if slot.is_empty():
					return   # board full — no further spawn-type activations possible
				actions.append({ "type": Action.GENERATE, "unit": inst, "ability": ab,
						"row": slot[0], "col": slot[1] })
			else:
				var target := _pick_ability_target(ab, board)
				if target == null and _ability_needs_manual(ab):
					continue
				actions.append({ "type": Action.GENERATE, "unit": inst, "ability": ab,
						"target": target })
			remaining -= ab.mana
			if ab.tap:
				break   # the holder is tapped when this executes — one tap ability per turn


# The ally a manually-targeted ability should hit: a HEALING ability aims at the most wounded
# own unit and is held when nobody is hurt (mirrors _pick_spell_target's heal logic — don't
# burn mana + the tap on a full-HP heal); anything else protects the biggest threat. Null when
# the ability needs no manual target, or nothing is worth targeting.
func _pick_ability_target(ab: AbilityData, board: CombatBoard) -> CardInstance:
	if not _ability_needs_manual(ab):
		return null
	var eligible: Array = []
	for u: CardInstance in _units(board.enemy_grid):
		for e: Effect in ab.effects:
			if e.trigger == Effect.Trigger.ON_PLAY \
					and e.targeting_policy == Effect.TargetingPolicy.MANUAL \
					and EffectSystem.passes_conditions(e.conditions, u):
				eligible.append(u)
				break
	if eligible.is_empty():
		return null
	if _ability_is_heal(ab):
		var wounded: Array = eligible.filter(func(u: CardInstance) -> bool:
			return u.current_health < u.get_attribute("max_health"))
		if wounded.is_empty():
			return null
		return _lowest_health(wounded)
	return _highest_attack(eligible)


func _ability_needs_manual(ab: AbilityData) -> bool:
	return ab.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY and e.targeting_policy == Effect.TargetingPolicy.MANUAL)


func _ability_is_heal(ab: AbilityData) -> bool:
	return ab.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY and e.attribute == "health" and e.amount > 0)


# ── Effect inspection ──────────────────────────────────────────────────────────────

func _has_on_play(inst: CardInstance) -> bool:
	return inst.data.effects.any(func(e: Effect) -> bool: return e.trigger == Effect.Trigger.ON_PLAY)


func _needs_manual(inst: CardInstance) -> bool:
	return inst.data.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY and e.targeting_policy == Effect.TargetingPolicy.MANUAL)


func _is_offensive(inst: CardInstance) -> bool:
	return inst.data.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY and e.amount < 0)


func _is_heal(inst: CardInstance) -> bool:
	return inst.data.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY and e.attribute == "health" and e.amount > 0)


func _health_damage(inst: CardInstance) -> int:
	var total := 0
	for e: Effect in inst.data.effects:
		if e.trigger == Effect.Trigger.ON_PLAY and e.attribute == "health" and e.amount < 0:
			total += -e.amount
	return total


# ── Grid + selection helpers ───────────────────────────────────────────────────────

func _occupancy(grid: Array) -> Array:
	var occ: Array = []
	for r in grid.size():
		occ.append([])
		for c in grid[r].size():
			occ[r].append(grid[r][c] != null)
	return occ


# Returns [row, col] of the frontmost empty slot (enemy front = lowest column) and
# marks it occupied in `occ`, or [] when the board is full.
func _take_front_slot(occ: Array) -> Array:
	var best: Array = []
	for r in occ.size():
		for c in occ[r].size():
			if not occ[r][c] and (best.is_empty() or c < best[1]):
				best = [r, c]
	if not best.is_empty():
		occ[best[0]][best[1]] = true
	return best


func _units(grid: Array) -> Array:
	var out: Array = []
	for row: Array in grid:
		for cell in row:
			if cell != null:
				out.append(cell)
	return out


func _highest_attack(units: Array) -> CardInstance:
	var best: CardInstance = null
	for u: CardInstance in units:
		if best == null or u.get_attribute("attack") > best.get_attribute("attack"):
			best = u
	return best


func _lowest_health(units: Array) -> CardInstance:
	var best: CardInstance = null
	for u: CardInstance in units:
		if best == null or u.current_health < best.current_health:
			best = u
	return best
