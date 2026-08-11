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
const ZAP := "_t_zap"                    # injected named effect: flat 1 damage
# (The rider/restrike fixtures — EMBER_*/RIDER_*/CAUGHT — died with those mechanisms,
# deleted 2026-08-11: never user-designed, disavowed 2026-08-09.)


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
	_fire_attack_ignites()
	_non_fire_does_not()
	_single_fire_does_not()
	_granted_fire_does_not_reach_a_count_gate()
	_burn_ticks_and_persists()
	_reattack_piles_on()
	_burning_authors_spread()
	_spread_propagates_and_snapshots()
	_spread_stays_in_bounds_and_on_side()
	_fade_dies_down_to_nothing()
	_hold_changes_nothing()
	_spread_only_fires_its_phase()
	_zero_stacks_is_expired_whatever_the_decay()
	_ablaze_authored_shape()
	_ablaze_burns_its_host()
	_ablaze_lights_the_ground_beneath_it()
	_the_fire_fuels_itself()
	_named_effect_expands()
	_named_effect_call_site_wins()
	_named_effect_round_trips()
	_named_effect_unknown_is_survivable()
	_named_effect_magnitude_scales()
	_named_effect_magnitude_defaults()
	_named_effect_magnitude_round_trips()
	_named_effect_magnitude_leaves_prose_alone()
	_arrival_burns_the_occupant()
	_arrival_whiffs_on_empty_ground()
	_cross_layer_catch_speaks_the_ground_language()
	StatusData._all.erase(FIRE_GRANT)
	StatusData._all.erase(SPREAD_ALL)
	StatusData._all.erase(SPREAD_FADE)
	StatusData._all.erase(SPREAD_HOLD)
	StatusData._all.erase(SPREAD_DOWN)
	StatusData._all.erase(SPREAD_MORPH)
	StatusData._all.erase(SPREAD_TOUCH)
	NamedEffects._all.erase(ZAP)


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
	w.place_unit(inst, r, c, side_owner)
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
	w.place_unit(atk, 1, 3, 0)
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
	w.place_unit(atk, 2, 3, 0)
	var def := _place(w, "pawn", 1, 2, 0)
	_attack(cascade, atk, def)
	check(w.slot_at(1, 2, 0).find_status("burning") == null,
			"one real fire is not two — a single-fire striker leaves the ground cold")


func _burn_ticks_and_persists() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _fire_unit(0)
	w.place_unit(atk, 0, 3, 0)
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
	w.place_unit(atk, 1, 3, 0)
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
	for slot: BoardSlot in w.locations.docked(BoardFacade.GROUND):
		var here := w.location_of(slot)
		if here.side != side_owner:
			continue
		var si: StatusInstance = slot.find_status(status_id)
		if si != null and not StatusEngine.is_expired(si):
			total += si.stacks
			cells.append(Vector2i(here.row, here.col))
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


# (The damage-rider suite died with the rider mechanism — deleted 2026-08-11, disavowed
# 2026-08-09, never user-designed. If damage ever carries follow-ons again, that is a
# DESIGNED payload delivery rule in the new schema, with its own suite.)


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


func _ablaze_burns_its_host() -> void:
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
	# Both fires deal the SAME named burn damage — one definition, two layers, so a retune
	# of "burn" reaches both. (The ignition-rider half of the old wildfire loop died with
	# the disavowed rider mechanism, 2026-08-11.)
	var ground := StatusData.get_status("burning")
	var unit_fire := StatusData.get_status("ablaze")
	check(ground != null and not ground.effects.is_empty()
			and unit_fire != null and not unit_fire.effects.is_empty(), "both fires deal a tick")
	if ground == null or ground.effects.is_empty() or unit_fire == null or unit_fire.effects.is_empty():
		return
	check_eq((ground.effects[0] as Effect).named_id, "burn", "the ground's tick is named burn damage")
	check_eq((unit_fire.effects[0] as Effect).named_id, "burn", "…and so is the unit's own")


# ── Named effects (NamedEffects + Effect."named") ────────────────────────────────────────


func _named_effect_expands() -> void:
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "burn"})
	check_eq(e.named_id, "burn", "the reference is remembered")
	check_eq(e.attribute, "damage_taken", "the template supplies the payload")
	check_eq(e.amount_int(), 1, "…its amount")
	check(not e.per_stack, "…its flat-damage flag")


func _named_effect_call_site_wins() -> void:
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "burn", "amount": 3})
	check_eq(e.amount_int(), 3, "an authored key overrides the template's (escape hatch)")


func _named_effect_round_trips() -> void:
	var authored: Dictionary = {"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "burn"}
	var back: Dictionary = Effect.from_dict(authored).to_dict()
	check_eq(str(back.get("named", "")), "burn", "serialisation keeps the reference")
	check(not back.has("attribute"), "…and the expansion never leaks into saved data")


func _named_effect_unknown_is_survivable() -> void:
	# Unknown name: loud push_error (visible in the run log), and the call site parses alone
	# rather than vanishing — a mistyped name degrades to an inert effect, not a crash.
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "self"}, "named": "_t_no_such_named"})
	check_eq(e.named_id, "_t_no_such_named", "the bad reference is still remembered")
	check_eq(e.amount_int(), 0, "…and supplies no payload")


# "Blind X" — the PARAMETERISED keyword. One authored template; the call site's amount is
# substituted into everything that scales with the number: the stacks applied AND their
# price to the enemy engine. Off-disk numbers deliberately (the shipped blind entry), like
# the status annotation pass — a template that stopped scaling its own price would pass a
# synthetic fixture and misprice every card in the game.


func _named_effect_magnitude_scales() -> void:
	var two := Effect.from_dict({"trigger": "on_play", "targeting_policy": "single_nearest",
			"named": "blind", "amount": 2})
	check_eq(two.status_id, "blind", "the keyword supplies the status")
	check_eq(two.status_stacks, 2, "…X stacks of it")
	check_eq(two.eval_add("value"), 2.0, "…and prices its carrier at X, from the same one number")
	var one := Effect.from_dict({"trigger": "on_play", "targeting_policy": "single_nearest",
			"named": "blind", "amount": 1})
	check_eq(one.status_stacks, 1, "a smaller X applies fewer stacks")
	check_eq(one.eval_add("value"), 1.0, "…and is worth proportionally less")


func _named_effect_magnitude_defaults() -> void:
	# No authored amount: the template's own is X — "Blind" alone means Blind 1.
	var e := Effect.from_dict({"trigger": "on_play", "targeting_policy": "single_nearest",
			"named": "blind"})
	check_eq(e.status_stacks, 1, "the template's amount is the default magnitude")
	check_eq(e.eval_add("value"), 1.0, "…and prices it")


func _named_effect_magnitude_round_trips() -> void:
	var authored: Dictionary = {"trigger": "on_play", "targeting_policy": "single_nearest",
			"named": "blind", "amount": 2}
	var back: Dictionary = Effect.from_dict(authored).to_dict()
	check_eq(str(back.get("named", "")), "blind", "the reference survives serialisation")
	check_eq(int(back.get("amount", 0)), 2, "…carrying its magnitude")
	check(not back.has("status") and not back.has("eval"),
			"…while the substitution never leaks into saved data")


func _named_effect_magnitude_leaves_prose_alone() -> void:
	# Substitution is STRUCTURAL: only a value that IS the placeholder is replaced, so a
	# template whose text merely mentions X keeps its text.
	var subbed: Dictionary = NamedEffects.substitute({
			"status": {"id": "blind", "stacks": "$X"},
			"note": "Blind X — apply X stacks",
			"eval": {"value": "$X"}}, 3.0) as Dictionary
	check_eq(str(subbed["note"]), "Blind X — apply X stacks", "prose mentioning X is not a placeholder")
	check_eq(int((subbed["status"] as Dictionary)["stacks"]), 3, "the nested placeholder took the magnitude")
	check_eq(float((subbed["eval"] as Dictionary)["value"]), 3.0, "…at any depth")


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


# (The restrike suite died with the restrike mechanism — deleted 2026-08-11, disavowed
# 2026-08-09, never user-designed. Stacked fire burns flat: one activation per firing.)


func _zero_stacks_is_expired_whatever_the_decay() -> void:
	var w := _world()
	var slot := w.slot_at(0, 2, 0)
	StatusEngine.apply(slot, SPREAD_HOLD, Effect.STATUS_DURATION_DEFAULT, 1, null)
	var si := slot.find_status(SPREAD_HOLD)
	check(si != null and not StatusEngine.is_expired(si), "one stack of a decay-none status lives")
	StatusEngine.shed_stack(slot, si)
	check(StatusEngine.is_expired(si), "0 stacks = no status, even at decay none — stacks ARE the quantity")
	check(slot.find_status(SPREAD_HOLD) == null, "shed_stack files the hygiene removal itself")
