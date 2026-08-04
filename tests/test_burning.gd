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
const SPREAD_DOWN := "_t_wildfire_down"  # chance 1, to "ground" — a unit lighting its own floor
const SPREAD_MORPH := "_t_wildfire_morph"  # to "ground", but the floor catches SPREAD_HOLD (spread.status)
const SPREAD_TOUCH := "_t_wildfire_touch"  # chance 1, arrival "_t_zap" — the flame's touch on arrival
const ZAP := "_t_zap"                    # injected named effect: flat 1 damage, no rider
const EMBER_ALL := "_t_ember_all"        # ground tick, restrike chance 1 — every extra flame burns
const EMBER_NONE := "_t_ember_none"      # ground tick, restrike chance 0 — the first flame alone
const EMBER_CATCHY := "_t_ember_catchy"  # restrike 1 AND rider 1 — every flame burns AND ignites
const EMBER_SELF := "_t_ember_self"      # unit-carried tick, restrike chance 1 (the ablaze shape)
const RIDER_SURE := "_t_rider_sure"      # ground damage whose rider ALWAYS ignites
const RIDER_NEVER := "_t_rider_never"    # …and one whose rider never does
const CAUGHT := "_t_caught"              # the status the riders apply


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
	StatusData._all[SPREAD_DOWN] = StatusData.from_dict({
		"id": SPREAD_DOWN, "decay": "none", "stacking": "stack",
		"spread": {"phase": "turn_start", "chance": 1.0, "decay_chance": 0.0, "to": "ground"}})
	StatusData._all[SPREAD_MORPH] = StatusData.from_dict({
		"id": SPREAD_MORPH, "decay": "none", "stacking": "stack",
		"spread": {"phase": "turn_start", "chance": 1.0, "decay_chance": 0.0,
				"to": "ground", "status": SPREAD_HOLD}})
	NamedEffects.all()   # force the registry load before injecting the test entry
	NamedEffects._all[ZAP] = {"attribute": "damage_taken", "amount": 1, "per_stack": false}
	StatusData._all[SPREAD_TOUCH] = StatusData.from_dict({
		"id": SPREAD_TOUCH, "decay": "none", "stacking": "stack",
		"spread": {"phase": "turn_start", "chance": 1.0, "decay_chance": 0.0, "arrival": ZAP}})
	StatusData._all[EMBER_ALL] = StatusData.from_dict({
		"id": EMBER_ALL, "decay": "none", "stacking": "stack", "effects": [
			{"trigger": {"kind": "event", "event": "turn_end"}, "targets": {"kind": "at_location"},
			"attribute": "damage_taken", "amount": 1, "per_stack": false, "per_stack_chance": 1.0}]})
	StatusData._all[EMBER_NONE] = StatusData.from_dict({
		"id": EMBER_NONE, "decay": "none", "stacking": "stack", "effects": [
			{"trigger": {"kind": "event", "event": "turn_end"}, "targets": {"kind": "at_location"},
			"attribute": "damage_taken", "amount": 1, "per_stack": false}]})
	StatusData._all[EMBER_CATCHY] = StatusData.from_dict({
		"id": EMBER_CATCHY, "decay": "none", "stacking": "stack", "effects": [
			{"trigger": {"kind": "event", "event": "turn_end"}, "targets": {"kind": "at_location"},
			"attribute": "damage_taken", "amount": 1, "per_stack": false, "per_stack_chance": 1.0,
			"riders": [{"chance": 1.0, "status": {"id": CAUGHT, "stacks": 1}}]}]})
	StatusData._all[EMBER_SELF] = StatusData.from_dict({
		"id": EMBER_SELF, "decay": "none", "stacking": "stack", "effects": [
			{"trigger": {"kind": "event", "event": "turn_end"}, "targets": {"kind": "self"},
			"attribute": "damage_taken", "amount": 1, "per_stack": false, "per_stack_chance": 1.0}]})
	StatusData._all[CAUGHT] = StatusData.from_dict({"id": CAUGHT, "decay": "none", "stacking": "stack"})
	StatusData._all[RIDER_SURE] = StatusData.from_dict({
		"id": RIDER_SURE, "decay": "none", "effects": [
			{"trigger": {"kind": "event", "event": "turn_end"}, "targets": {"kind": "at_location"},
			"attribute": "damage_taken", "amount": 1, "per_stack": false,
			"riders": [{"chance": 1.0, "status": {"id": CAUGHT, "stacks": 1}}]}]})
	StatusData._all[RIDER_NEVER] = StatusData.from_dict({
		"id": RIDER_NEVER, "decay": "none", "effects": [
			{"trigger": {"kind": "event", "event": "turn_end"}, "targets": {"kind": "at_location"},
			"attribute": "damage_taken", "amount": 1, "per_stack": false,
			"riders": [{"chance": 0.0, "status": {"id": CAUGHT, "stacks": 1}}]}]})
	_fire_attack_ignites()
	_non_fire_does_not()
	_single_fire_does_not()
	_granted_fire_does_not_reach_a_count_gate()
	# The two damage-ARITHMETIC tests measure the ground's tick alone. Burning's rider would
	# add a second, RANDOMLY-lit fire on the occupant (ablaze deals its own 1 each round) and
	# its restrike chance a random extra point, so the sums would ride coin flips. Calmed for
	# their duration — both behaviors are proven deterministically further down, with
	# chance-1 and chance-0 test statuses.
	var saved_calm := _tick_calm("burning")
	_burn_ticks_and_persists()
	_reattack_piles_on()
	_tick_calm_off("burning", saved_calm)
	_burning_authors_spread()
	_spread_propagates_and_snapshots()
	_spread_stays_in_bounds_and_on_side()
	_fade_dies_down_to_nothing()
	_hold_changes_nothing()
	_spread_only_fires_its_phase()
	_zero_stacks_is_expired_whatever_the_decay()
	_rider_ignites_on_damage()
	_rider_chance_gates_it()
	_rider_needs_a_victim()
	_rider_rolls_once_per_instance_not_per_point()
	_rider_round_trips()
	_ablaze_authored_shape()
	_ablaze_burns_its_host()
	_ablaze_lights_the_ground_beneath_it()
	_the_fire_fuels_itself()
	_named_effect_expands()
	_named_effect_call_site_wins()
	_named_effect_round_trips()
	_named_effect_unknown_is_survivable()
	_arrival_burns_the_occupant()
	_arrival_whiffs_on_empty_ground()
	_cross_layer_catch_speaks_the_ground_language()
	_restrike_every_extra_flame_burns()
	_restrike_one_flame_never_restrikes()
	_restrike_off_burns_once()
	_restrike_carries_the_rider_per_instance()
	_restrike_on_a_unit_carrier()
	_burn_authors_the_restrike()
	StatusData._all.erase(EMBER_ALL)
	StatusData._all.erase(EMBER_NONE)
	StatusData._all.erase(EMBER_CATCHY)
	StatusData._all.erase(EMBER_SELF)
	StatusData._all.erase(FIRE_GRANT)
	StatusData._all.erase(SPREAD_ALL)
	StatusData._all.erase(SPREAD_FADE)
	StatusData._all.erase(SPREAD_HOLD)
	StatusData._all.erase(SPREAD_DOWN)
	StatusData._all.erase(SPREAD_MORPH)
	StatusData._all.erase(SPREAD_TOUCH)
	NamedEffects._all.erase(ZAP)
	StatusData._all.erase(RIDER_SURE)
	StatusData._all.erase(RIDER_NEVER)
	StatusData._all.erase(CAUGHT)


# Calms a status tick's randomness (returning what was lifted) so a test can measure the
# tick alone: the damage riders (a random ignition adds a second fire) AND the restrike
# chance (an extra flame adds a random second point). Paired with _tick_calm_off.
func _tick_calm(status_id: String) -> Dictionary:
	var sd := StatusData.get_status(status_id)
	if sd == null or sd.effects.is_empty():
		return {}
	var tick: Effect = sd.effects[0]
	var saved: Dictionary = {"riders": tick.riders, "restrike": tick.per_stack_chance}
	tick.riders = []
	tick.per_stack_chance = 0.0
	return saved


func _tick_calm_off(status_id: String, saved: Dictionary) -> void:
	var sd := StatusData.get_status(status_id)
	if sd == null or sd.effects.is_empty() or saved.is_empty():
		return
	var tick: Effect = sd.effects[0]
	tick.riders = saved["riders"]
	tick.per_stack_chance = float(saved["restrike"])


# The stack count the fire_scorches_ground INNATE rule authors, read from the rule itself
# rather than pinned here: these are PLUMBING tests (a fire strike lights the struck slot,
# the pile grows per strike, the fire never fades on its own), and retuning the number in
# data/innate_effects/ must not fail them. See EVAL_CRITERIA_BRIEF.md's testing doctrine —
# pin the computation, never the tuning.
func _scorch_stacks() -> int:
	for e: Effect in InnateEffects.all():
		if e.status_id == "burning":
			return e.status_stacks
	return 0


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


# A striker that satisfies the scorch rule's gate. The rule is authored as a composition
# COUNT ("really built from 2+ fire" — the fire_fire units), so the fixture is doubly fire:
# a single-fire unit deliberately does NOT scorch (see _single_fire_does_not).
func _fire_unit(side_owner: int) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_t_fire_striker", "display_name": "T", "cost": 1, "attack": 2, "health": 3,
		"speed": 1, "elements": ["fire", "fire"]}))
	inst.owner = side_owner
	return inst


# A striker with exactly ONE real fire — fire, but not fire_fire.
func _single_fire_unit(side_owner: int) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_t_single_fire_striker", "display_name": "T", "cost": 1, "attack": 2, "health": 3,
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
	check(si != null and si.stacks == _scorch_stacks(),
			"burning arrives with the stack count the innate rule authors")
	check(w.slot_at(0, 1, 3).find_status("burning") == null, "the attacker's own ground stays cold")


func _non_fire_does_not() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _place(w, "pawn", 0, 0, 3)
	var def := _place(w, "pawn", 1, 0, 0)
	_attack(cascade, atk, def)
	check(w.slot_at(1, 0, 0).find_status("burning") == null,
			"a non-fire strike leaves the ground alone")


# TWO LENSES, TWO QUESTIONS (user ruling 2026-08-04). The scorch rule gates on a
# composition COUNT, which reads what the card really IS. A blessing makes a unit be
# TREATED AS fire — it never claimed how MUCH fire the unit is — so it cannot carry a
# unit through a quantity gate. (The general capability, grants satisfying PRESENCE
# conditions, is proven in test_composition_grants; this pins which lens THIS rule uses.)
func _granted_fire_does_not_reach_a_count_gate() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _place(w, "knight", 0, 2, 3)
	StatusEngine.apply(atk, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	var def := _place(w, "pawn", 1, 2, 0)
	check(EffectCondition.from_dict({"composition": ["fire"]}).evaluate(atk),
			"the blessed knight IS treated as fire (the presence lens)")
	_attack(cascade, atk, def)
	check(w.slot_at(1, 2, 0).find_status("burning") == null,
			"…but a blessing is not a quantity, so it never satisfies the two-fire gate")


func _single_fire_does_not() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _single_fire_unit(0)
	atk.row = 2
	atk.col = 3
	var arow: Array = w.player_grid[2]
	arow[3] = atk
	var def := _place(w, "pawn", 1, 2, 0)
	_attack(cascade, atk, def)
	check(w.slot_at(1, 2, 0).find_status("burning") == null,
			"one real fire is not two — a single-fire striker leaves the ground cold")


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
		check(si != null and si.stacks == _scorch_stacks(),
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
	check(si != null and si.stacks == _scorch_stacks(), "a round of burning sheds no stacks (no phase decay)")
	_attack(cascade, atk, def)
	check(si != null and si.stacks == 2 * _scorch_stacks(),
			"a fresh strike piles another rule's-worth of stacks onto the fire")
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


func _turn_end(cascade: CombatCascade) -> void:
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_end")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the turn-end pass resolves synchronously under the null presenter")


# ── Damage riders (Effect.riders) ────────────────────────────────────────────────────────
# The follow-on a damage instance CARRIES onto whoever took it — what makes burning ground
# set its occupant alight without inventing a fire-damage TYPE.


func _rider_ignites_on_damage() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 1, 0, 1)
	StatusEngine.apply(w.slot_at(1, 0, 1), RIDER_SURE, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_end(cascade)
	check(victim.find_status(CAUGHT) != null, "burn damage carries its rider onto the unit that took it")
	check_eq(victim.current_shield, 2, "…and the damage itself still lands")


func _rider_chance_gates_it() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 1, 0, 1)
	StatusEngine.apply(w.slot_at(1, 0, 1), RIDER_NEVER, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_end(cascade)
	check(victim.find_status(CAUGHT) == null, "a rider that loses its roll applies nothing")
	check_eq(victim.current_shield, 2, "…while the damage lands regardless")


func _rider_needs_a_victim() -> void:
	# Nobody standing there = no damage instance = no rider. The rider rides the damage.
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	StatusEngine.apply(w.slot_at(1, 2, 1), RIDER_SURE, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_end(cascade)
	check(w.slot_at(1, 2, 1).find_status(RIDER_SURE) != null, "the empty fire burns on")
	check(true, "an empty slot's burn carries its rider nowhere (no crash, no victim)")


# THE RULE, stated as a test: one damage INSTANCE, one roll — the amount is not a multiplier.
# A 3-damage tick ignites exactly as often as a 1-damage one; more rolls means more instances.
func _rider_rolls_once_per_instance_not_per_point() -> void:
	var heavy := "_t_rider_heavy"
	StatusData._all[heavy] = StatusData.from_dict({
		"id": heavy, "decay": "none", "effects": [
			{"trigger": {"kind": "event", "event": "turn_end"}, "targets": {"kind": "at_location"},
			"attribute": "damage_taken", "amount": 3, "per_stack": false,
			"riders": [{"chance": 1.0, "status": {"id": CAUGHT, "stacks": 1}}]}]})
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 1, 1, 2)
	StatusEngine.apply(w.slot_at(1, 1, 2), heavy, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_end(cascade)
	var si := victim.find_status(CAUGHT)
	check(si != null and si.stacks == 1,
			"three points of damage in ONE instance still rolls its rider exactly once")
	StatusData._all.erase(heavy)


func _rider_round_trips() -> void:
	var authored: Dictionary = {"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "at_location"}, "attribute": "damage_taken", "amount": 1,
			"riders": [{"chance": 0.5, "status": {"id": "ablaze", "duration": -999, "stacks": 2}}]}
	var e := Effect.from_dict(authored)
	check_eq(e.riders.size(), 1, "a rider parses off the authored effect")
	var back: Dictionary = e.to_dict()
	var rl: Array = back.get("riders", [])
	check_eq(rl.size(), 1, "…and survives the round trip")
	if rl.is_empty():
		return
	var r: Dictionary = rl[0]
	check(is_equal_approx(float(r.get("chance", 1.0)), 0.5), "the chance round-trips")
	check_eq(str((r.get("status", {}) as Dictionary).get("id", "")), "ablaze", "the status id round-trips")
	check_eq(int((r.get("status", {}) as Dictionary).get("stacks", 0)), 2, "the stack count round-trips")


# ── Ablaze: burning, on the piece layer ──────────────────────────────────────────────────


func _ablaze_authored_shape() -> void:
	var sd := StatusData.get_status("ablaze")
	check(sd != null, "ablaze is authored")
	if sd == null:
		return
	check_eq(sd.display_name, "Burning", "it reads as Burning — one fire, two layers")
	check_eq(sd.decay, StatusData.DECAY_NONE, "no phase decay — the spread roll is its lifetime")
	check_eq(str(sd.spread.get("to", "adjacent")), "ground", "a burning unit lights the floor, not its neighbours")
	# The ground's burn is what sets units alight — the one authored bridge between layers.
	var ground := StatusData.get_status("burning")
	check(ground != null and not ground.effects.is_empty(), "burning still deals its tick")
	if ground == null or ground.effects.is_empty():
		return
	var tick: Effect = ground.effects[0]
	check_eq(tick.riders.size(), 1, "burning's damage carries exactly one rider")
	if tick.riders.is_empty():
		return
	check_eq(str((tick.riders[0] as Dictionary)["status_id"]), "ablaze", "…and that rider is ablaze")
	check(is_equal_approx(float((tick.riders[0] as Dictionary)["chance"]), 0.3333),
			"…at one third per instance of burn damage")


func _ablaze_burns_its_host() -> void:
	# Ablaze's own tick is burn damage, so its rider could randomly deepen the pile and its
	# restrike chance add a random point — calmed for the arithmetic here (both behaviors
	# are proven as data/deterministically elsewhere).
	var saved := _tick_calm("ablaze")
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 0, 1, 1)   # 6 HP, 3 shield
	StatusEngine.apply(victim, "ablaze", Effect.STATUS_DURATION_DEFAULT, 3, null)
	_turn_end(cascade)
	check_eq(victim.current_shield, 2, "a burning unit takes 1 damage at round end")
	var si := victim.find_status("ablaze")
	check(si != null and si.stacks == 3, "…and the fire on it doesn't tick away — only the roll fades it")
	_turn_end(cascade)
	check_eq(victim.current_shield, 1, "three stacks still burn for exactly 1 — fire's heat is flat")
	_tick_calm_off("ablaze", saved)


func _ablaze_lights_the_ground_beneath_it() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var host := _place(w, "pawn", 0, 2, 1)
	StatusEngine.apply(host, SPREAD_DOWN, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_start(cascade)
	check(w.slot_at(0, 2, 1).find_status(SPREAD_DOWN) != null,
			"a burning unit sets light to the slot it stands on")
	var still := host.find_status(SPREAD_DOWN)
	check(still != null and still.stacks == 1, "…keeping its own flame (propagation copies)")
	# ACROSS layers at ONE address — never sideways to a neighbouring slot.
	check(w.slot_at(0, 2, 0).find_status(SPREAD_DOWN) == null
			and w.slot_at(0, 1, 1).find_status(SPREAD_DOWN) == null,
			"a unit's fire goes DOWN, never to the tiles around it")


func _the_fire_fuels_itself() -> void:
	# THE WILDFIRE RULING (user, 2026-08-03): ablaze's own tick IS burn damage, rider and
	# all — a burning unit may re-light itself, because fire fuels itself by burning things.
	# Both fires speak the same name, so the self-fueling is a consequence, not an authoring.
	var ground := StatusData.get_status("burning")
	var unit_fire := StatusData.get_status("ablaze")
	check(ground != null and not ground.effects.is_empty()
			and unit_fire != null and not unit_fire.effects.is_empty(), "both fires deal a tick")
	if ground == null or ground.effects.is_empty() or unit_fire == null or unit_fire.effects.is_empty():
		return
	check_eq((ground.effects[0] as Effect).named_id, "burn", "the ground's tick is named burn damage")
	check_eq((unit_fire.effects[0] as Effect).named_id, "burn", "…and so is the unit's own")
	check(not (unit_fire.effects[0] as Effect).riders.is_empty(),
			"a burning unit's tick carries the ignition rider — the fire fuels itself")


# ── Named effects (NamedEffects + Effect."named") ────────────────────────────────────────


func _named_effect_expands() -> void:
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "burn"})
	check_eq(e.named_id, "burn", "the reference is remembered")
	check_eq(e.attribute, "damage_taken", "the template supplies the payload")
	check_eq(e.amount_int(), 1, "…its amount")
	check(not e.per_stack, "…its flat-damage flag")
	check_eq(e.riders.size(), 1, "…and its rider")
	if e.riders.is_empty():
		return
	check_eq(str((e.riders[0] as Dictionary)["status_id"]), "ablaze", "the rider ignites ablaze")


func _named_effect_call_site_wins() -> void:
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "burn", "amount": 3})
	check_eq(e.amount_int(), 3, "an authored key overrides the template's (escape hatch)")
	check_eq(e.riders.size(), 1, "…without disturbing the rest of the template")


func _named_effect_round_trips() -> void:
	var authored: Dictionary = {"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "burn"}
	var back: Dictionary = Effect.from_dict(authored).to_dict()
	check_eq(str(back.get("named", "")), "burn", "serialisation keeps the reference")
	check(not back.has("riders") and not back.has("attribute"),
			"…and the expansion never leaks into saved data")


func _named_effect_unknown_is_survivable() -> void:
	# Unknown name: loud push_error (visible in the run log), and the call site parses alone
	# rather than vanishing — a mistyped name degrades to an inert effect, not a crash.
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "_t_no_such_named"})
	check_eq(e.named_id, "_t_no_such_named", "the bad reference is still remembered")
	check_eq(e.amount_int(), 0, "…and supplies no payload")


# ── Spread arrival (the flame's touch) + cross-layer catch ──────────────────────────────


func _arrival_burns_the_occupant() -> void:
	# One stack, certain spread, a unit on EVERY orthogonal neighbour — wherever the leap
	# lands, its occupant takes the arrival effect's flat 1. Total shield across the four
	# neighbours drops by exactly 1: one arrival, one touch, however the die picked the cell.
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var neighbours: Array = []
	for cell: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 2), Vector2i(2, 1)]:
		neighbours.append(_place(w, "rook", 0, cell.x, cell.y))   # rook: 3 shield each
	StatusEngine.apply(w.slot_at(0, 1, 1), SPREAD_TOUCH, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_start(cascade)
	var total := 0
	for u: CardInstance in neighbours:
		total += u.current_shield
	check_eq(total, 11, "the arriving flame touches the caught cell's occupant for exactly 1")
	check_eq(int(_side_spread(w, 0, SPREAD_TOUCH)["total"]), 2, "…and the stack still lands")


func _arrival_whiffs_on_empty_ground() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	StatusEngine.apply(w.slot_at(0, 1, 1), SPREAD_TOUCH, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_start(cascade)
	check_eq(int(_side_spread(w, 0, SPREAD_TOUCH)["total"]), 2,
			"an arrival with nobody standing there is a legal miss — the fire still spreads")


func _cross_layer_catch_speaks_the_ground_language() -> void:
	# spread.status: a cross-layer leap arrives AS the destination layer's status. The
	# mechanic, with test statuses…
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var host := _place(w, "pawn", 0, 2, 2)
	StatusEngine.apply(host, SPREAD_MORPH, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_start(cascade)
	check(w.slot_at(0, 2, 2).find_status(SPREAD_HOLD) != null,
			"the floor catches the status the spread NAMES, not the roller's own")
	check(w.slot_at(0, 2, 2).find_status(SPREAD_MORPH) == null,
			"…and never the roller's own id")
	# …and the authored fact it exists for: ablaze lights the ground as BURNING. Ablaze on a
	# slot would be a self-targeting status the slot dispatch fence refuses — this datum is
	# what keeps the wildfire loop legal.
	var sd := StatusData.get_status("ablaze")
	check(sd != null and str(sd.spread.get("status", "")) == "burning",
			"ablaze's ground catch is authored as burning")
	var ground := StatusData.get_status("burning")
	check(ground != null and str(ground.spread.get("arrival", "")) == "burn",
			"burning's leap carries the burn touch onto whoever stands there")


# ── Restrikes (Effect.per_stack_chance — "each flame beyond the first may burn again") ──


func _restrike_every_extra_flame_burns() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 1, 0, 1)   # 6 HP, 3 shield
	StatusEngine.apply(w.slot_at(1, 0, 1), EMBER_ALL, Effect.STATUS_DURATION_DEFAULT, 3, null)
	_turn_end(cascade)
	check_eq(victim.current_shield, 0,
			"3 stacks at certain restrike: the first burns for sure, both extras burn again — 3 total")


func _restrike_one_flame_never_restrikes() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 1, 0, 1)
	StatusEngine.apply(w.slot_at(1, 0, 1), EMBER_ALL, Effect.STATUS_DURATION_DEFAULT, 1, null)
	_turn_end(cascade)
	check_eq(victim.current_shield, 2,
			"one flame burns exactly once, even at certain restrike — only stacks PAST the first roll")


func _restrike_off_burns_once() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 1, 0, 1)
	StatusEngine.apply(w.slot_at(1, 0, 1), EMBER_NONE, Effect.STATUS_DURATION_DEFAULT, 5, null)
	_turn_end(cascade)
	check_eq(victim.current_shield, 2,
			"no restrike authored: five stacks still burn for exactly 1 — today's flat fire")


func _restrike_carries_the_rider_per_instance() -> void:
	# Each restrike is a fresh damage INSTANCE, so the rider rolls with every one — the
	# one-roll-per-instance rule, now visibly paying off: 3 flames, 3 catches.
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var victim := _place(w, "rook", 1, 1, 1)
	StatusEngine.apply(w.slot_at(1, 1, 1), EMBER_CATCHY, Effect.STATUS_DURATION_DEFAULT, 3, null)
	_turn_end(cascade)
	check_eq(victim.current_shield, 0, "three flames, three points")
	var si := victim.find_status(CAUGHT)
	check(si != null and si.stacks == 3,
			"…and three instances each rolled the rider — 3 catches, not 1")


func _restrike_on_a_unit_carrier() -> void:
	# The identical rule through the UNIT dispatch (trigger_grouped) — the ablaze shape.
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var host := _place(w, "rook", 0, 1, 2)
	StatusEngine.apply(host, EMBER_SELF, Effect.STATUS_DURATION_DEFAULT, 3, null)
	_turn_end(cascade)
	check_eq(host.current_shield, 0, "a unit's own stacked fire restrikes the same way — 3 total")


func _burn_authors_the_restrike() -> void:
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "burn"})
	check(is_equal_approx(e.per_stack_chance, 0.25),
			"the burn template carries the restrike chance — every burn tick inherits it")


func _zero_stacks_is_expired_whatever_the_decay() -> void:
	var w := _world()
	var slot := w.slot_at(0, 2, 0)
	StatusEngine.apply(slot, SPREAD_HOLD, Effect.STATUS_DURATION_DEFAULT, 1, null)
	var si := slot.find_status(SPREAD_HOLD)
	check(si != null and not StatusEngine.is_expired(si), "one stack of a decay-none status lives")
	StatusEngine.shed_stack(slot, si)
	check(StatusEngine.is_expired(si), "0 stacks = no status, even at decay none — stacks ARE the quantity")
	check(slot.find_status(SPREAD_HOLD) == null, "shed_stack files the hygiene removal itself")
