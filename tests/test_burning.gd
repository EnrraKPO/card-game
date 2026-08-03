extends TestCase

# Burning — the slot layer's first live content, and the proof-of-tech for the wildfire
# cornerstone: the fire_scorches_ground INNATE rule (every unit that counts as fire sets
# the struck slot burning) + the burning status (the occupant takes 1 damage, shield-first,
# at each round's end; the fire outlives and ignores whoever moves through it) + the SPREAD
# tier (CombatCascade._spread_ground): at turn start each stack rolls once — it may leap to
# a random adjacent slot, else it may die down; the roll IS the fire's whole lifetime
# (burning never phase-decays). Spread mechanics are proven with chance-0/1 test statuses
# so no roll is ever left to luck; burning's own 10%/25% numbers are checked as data.


func suite_name() -> String:
	return "Burning ground"


const FIRE_GRANT := "_t_burn_fire_grant"
const SPREAD_ALL := "_t_wildfire_all"    # chance 1 — every stack leaps, none fades
const SPREAD_FADE := "_t_wildfire_fade"  # chance 0, decay_chance 1 — every stack dies down
const SPREAD_HOLD := "_t_wildfire_hold"  # chance 0, decay_chance 0 — nothing ever happens


func run() -> void:
	StatusData._all[FIRE_GRANT] = StatusData.from_dict({
		"id": FIRE_GRANT, "decay": "none", "effects": [
			{"trigger": {"kind": "while"}, "targets": {"kind": "self"}, "grants": ["fire"]}]})
	StatusData._all[SPREAD_ALL] = StatusData.from_dict({
		"id": SPREAD_ALL, "decay": "none", "stacking": "stack",
		"spread": {"phase": "turn_start", "chance": 1.0, "decay_chance": 0.0}})
	StatusData._all[SPREAD_FADE] = StatusData.from_dict({
		"id": SPREAD_FADE, "decay": "none", "stacking": "stack",
		"spread": {"phase": "turn_start", "chance": 0.0, "decay_chance": 1.0}})
	StatusData._all[SPREAD_HOLD] = StatusData.from_dict({
		"id": SPREAD_HOLD, "decay": "none", "stacking": "stack",
		"spread": {"phase": "turn_start", "chance": 0.0, "decay_chance": 0.0}})
	_fire_attack_ignites()
	_non_fire_does_not()
	_granted_fire_counts()
	_burn_ticks_and_persists()
	_reattack_piles_on()
	_burning_authors_spread()
	_spread_propagates_and_snapshots()
	_spread_stays_in_bounds_and_on_side()
	_fade_dies_down_to_nothing()
	_hold_changes_nothing()
	_spread_only_fires_its_phase()
	_zero_stacks_is_expired_whatever_the_decay()
	StatusData._all.erase(FIRE_GRANT)
	StatusData._all.erase(SPREAD_ALL)
	StatusData._all.erase(SPREAD_FADE)
	StatusData._all.erase(SPREAD_HOLD)


func _world() -> CombatWorld:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	return w


func _place(w: CombatWorld, card_id: String, side_owner: int, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	inst.owner = side_owner
	inst.row = r
	inst.col = c
	var grid: Array = w.grid_of(side_owner)
	var grid_row: Array = grid[r]
	grid_row[c] = inst
	return inst


func _fire_unit(side_owner: int) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_t_fire_striker", "display_name": "T", "cost": 1, "attack": 2, "health": 3,
		"speed": 1, "elements": ["fire"]}))
	inst.owner = side_owner
	return inst


# The attack MOMENT, as combat broadcasts it (the swing event; whether damage follows is a
# separate mutation and irrelevant to ignition). Synchronous under the null presenter.
func _attack(cascade: CombatCascade, atk: CardInstance, def: CardInstance) -> void:
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.broadcast(GameEvent.make(&"attack", atk, def))
		done[0] = true
	chain.call()
	check(bool(done[0]), "the attack broadcast stays synchronous under the null presenter")


func _fire_attack_ignites() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _fire_unit(0)
	atk.row = 1
	atk.col = 3
	var arow: Array = w.player_grid[1]
	arow[3] = atk
	var def := _place(w, "pawn", 1, 1, 0)
	_attack(cascade, atk, def)
	var si := w.slot_at(1, 1, 0).find_status("burning")
	check(si != null, "a fire unit's strike sets the struck slot burning")
	check(si != null and si.stacks == 2, "burning arrives as its authored two stacks")
	check(w.slot_at(0, 1, 3).find_status("burning") == null, "the attacker's own ground stays cold")


func _non_fire_does_not() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _place(w, "pawn", 0, 0, 3)
	var def := _place(w, "pawn", 1, 0, 0)
	_attack(cascade, atk, def)
	check(w.slot_at(1, 0, 0).find_status("burning") == null,
			"a non-fire strike leaves the ground alone")


func _granted_fire_counts() -> void:
	# The innate gates on the EFFECTIVE composition: a unit merely COUNTING AS fire (a
	# standing grant) scorches like the real thing — the condition-driven design's payoff.
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _place(w, "knight", 0, 2, 3)
	StatusEngine.apply(atk, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	var def := _place(w, "pawn", 1, 2, 0)
	_attack(cascade, atk, def)
	check(w.slot_at(1, 2, 0).find_status("burning") != null,
			"a granted-fire unit ignites the ground too")


func _burn_ticks_and_persists() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _fire_unit(0)
	atk.row = 0
	atk.col = 3
	var arow: Array = w.player_grid[0]
	arow[3] = atk
	var def := _place(w, "rook", 1, 0, 0)   # 6 HP, 3 shield — the tick is shield-first damage
	_attack(cascade, atk, def)
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_end")
		check_eq(def.current_shield, 2, "the occupant takes 1 shield-first damage at round end")
		check_eq(def.current_health, 6, "…and health holds while shield stands")
		await cascade.resolve_event(&"turn_end")
		check_eq(def.current_shield, 1, "the second round burns again")
		var si := w.slot_at(1, 0, 0).find_status("burning")
		check(si != null and si.stacks == 2,
				"the fire never goes out on its own — only a failed spread roll fades it")
		await cascade.resolve_event(&"turn_end")
		check_eq(def.current_shield, 0, "…so the third round still burns")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the burn rounds resolve synchronously")


# Stacks ADD (the pile grows per strike, clamped by max_stacks) — and however tall the pile,
# the tick stays flat 1 damage (per_stack=false: stacks mean flames, never heat).
func _reattack_piles_on() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _fire_unit(0)
	atk.row = 1
	atk.col = 3
	var arow: Array = w.player_grid[1]
	arow[3] = atk
	var def := _place(w, "rook", 1, 1, 0)   # 6 HP, 3 shield — room to measure several ticks
	_attack(cascade, atk, def)
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_end")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the interim round resolves synchronously")
	var si := w.slot_at(1, 1, 0).find_status("burning")
	check(si != null and si.stacks == 2, "a round of burning sheds no stacks (no phase decay)")
	_attack(cascade, atk, def)
	check(si != null and si.stacks == 4, "a fresh strike piles two more stacks onto the fire")
	var done2: Array = [false]
	var chain2 := func() -> void:
		await cascade.resolve_event(&"turn_end")
		done2[0] = true
	chain2.call()
	check(bool(done2[0]), "the stacked round resolves synchronously")
	check_eq(def.current_shield, 1, "four stacks still burn for exactly 1 — fire's heat is flat")


# ── The spread tier ──────────────────────────────────────────────────────────────────────


# One turn_start pass under a null presenter, synchronously — the spread tier must never
# actually await in a simulation-shaped run.
func _turn_start(cascade: CombatCascade) -> void:
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_start")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the spread pass resolves synchronously under the null presenter")


# Total stacks of `status_id` across one half's ground, plus the set of addresses carrying it.
func _side_spread(w: CombatWorld, side_owner: int, status_id: String) -> Dictionary:
	var total := 0
	var cells: Array = []
	for key: Vector3i in w.slots:
		if key.x != side_owner:
			continue
		var si: StatusInstance = (w.slots[key] as BoardSlot).find_status(status_id)
		if si != null and not StatusEngine.is_expired(si):
			total += si.stacks
			cells.append(Vector2i(key.y, key.z))
	return {"total": total, "cells": cells}


func _burning_authors_spread() -> void:
	var sd := StatusData.get_status("burning")
	check(sd != null and not sd.spread.is_empty(), "burning authors a spread block")
	if sd == null or sd.spread.is_empty():
		return
	check(is_equal_approx(float(sd.spread.get("chance", 0.0)), 0.2),
			"each flame leaps at 20%")
	check(is_equal_approx(float(sd.spread.get("decay_chance", 0.0)), 0.4),
			"…else dies down at 40%")
	check_eq(sd.decay, StatusData.DECAY_NONE, "burning has no phase decay — the roll is its lifetime")


func _spread_propagates_and_snapshots() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	StatusEngine.apply(w.slot_at(0, 1, 1), SPREAD_ALL, Effect.STATUS_DURATION_DEFAULT, 3, null)
	_turn_start(cascade)
	var origin := w.slot_at(0, 1, 1).find_status(SPREAD_ALL)
	check(origin != null and origin.stacks == 3, "propagation COPIES a stack out — the source keeps its own")
	var side: Dictionary = _side_spread(w, 0, SPREAD_ALL)
	# Certain spread, 3 stacks: exactly 3 new stacks land. More would mean a stack that
	# ARRIVED this pass also rolled — the snapshot rule broken, one chain sweeping the board.
	check_eq(int(side["total"]), 6, "three rolls place exactly three new stacks — arrivals never roll the pass that lit them")
	for cell: Vector2i in side["cells"]:
		if cell == Vector2i(1, 1):
			continue
		check(absi(cell.x - 1) + absi(cell.y - 1) == 1,
				"every catch is orthogonally adjacent to the origin (landed r%d c%d)" % [cell.x, cell.y])
	check_eq(int(_side_spread(w, 1, SPREAD_ALL)["total"]), 0, "the battle line is a wall — nothing crosses")


func _spread_stays_in_bounds_and_on_side() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	StatusEngine.apply(w.slot_at(1, 0, 0), SPREAD_ALL, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_start(cascade)
	var side: Dictionary = _side_spread(w, 1, SPREAD_ALL)
	check_eq(int(side["total"]), 2, "a corner flame still finds a neighbour")
	for cell: Vector2i in side["cells"]:
		var in_bounds := cell.x >= 0 and cell.x < BoardData.ROWS and cell.y >= 0 and cell.y < BoardData.COLS
		check(in_bounds, "the catch stays on the board (landed r%d c%d)" % [cell.x, cell.y])
	check_eq(int(_side_spread(w, 0, SPREAD_ALL)["total"]), 0, "…and on its own half")


func _fade_dies_down_to_nothing() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	StatusEngine.apply(w.slot_at(0, 2, 2), SPREAD_FADE, Effect.STATUS_DURATION_DEFAULT, 3, null)
	_turn_start(cascade)
	check(w.slot_at(0, 2, 2).find_status(SPREAD_FADE) == null,
			"certain fading kills every stack in one pass — the fire is out")
	check_eq(int(_side_spread(w, 0, SPREAD_FADE)["total"]), 0, "and nothing leapt anywhere")


func _hold_changes_nothing() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	StatusEngine.apply(w.slot_at(0, 0, 2), SPREAD_HOLD, Effect.STATUS_DURATION_DEFAULT, 3, null)
	_turn_start(cascade)
	var si := w.slot_at(0, 0, 2).find_status(SPREAD_HOLD)
	check(si != null and si.stacks == 3, "failed rolls leave the pile exactly as it was")
	check_eq(int(_side_spread(w, 0, SPREAD_HOLD)["total"]), 3, "…and light nothing new")


func _spread_only_fires_its_phase() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	StatusEngine.apply(w.slot_at(0, 1, 2), SPREAD_ALL, Effect.STATUS_DURATION_DEFAULT, 2, null)
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_end")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the off-phase pass resolves synchronously")
	check_eq(int(_side_spread(w, 0, SPREAD_ALL)["total"]), 2,
			"a turn_start spread never rolls at turn_end")


func _zero_stacks_is_expired_whatever_the_decay() -> void:
	var w := _world()
	var slot := w.slot_at(0, 2, 0)
	StatusEngine.apply(slot, SPREAD_HOLD, Effect.STATUS_DURATION_DEFAULT, 1, null)
	var si := slot.find_status(SPREAD_HOLD)
	check(si != null and not StatusEngine.is_expired(si), "one stack of a decay-none status lives")
	StatusEngine.shed_stack(slot, si)
	check(StatusEngine.is_expired(si), "0 stacks = no status, even at decay none — stacks ARE the quantity")
	check(slot.find_status(SPREAD_HOLD) == null, "shed_stack files the hygiene removal itself")
