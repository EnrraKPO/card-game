extends TestCase

# Burning — the slot layer's first live content, and the proof-of-tech for the wildfire
# cornerstone: the fire_scorches_ground INNATE rule (every unit that counts as fire sets
# the struck slot burning) + the burning status (the occupant takes 1 damage, shield-first,
# at each round's end; the fire outlives and ignores whoever moves through it).


func suite_name() -> String:
	return "Burning ground"


const FIRE_GRANT := "_t_burn_fire_grant"


func run() -> void:
	StatusData._all[FIRE_GRANT] = StatusData.from_dict({
		"id": FIRE_GRANT, "decay": "none", "effects": [
			{"trigger": {"kind": "while"}, "targets": {"kind": "self"}, "grants": ["fire"]}]})
	_fire_attack_ignites()
	_non_fire_does_not()
	_granted_fire_counts()
	_burn_ticks_and_expires()
	_reattack_refreshes()
	StatusData._all.erase(FIRE_GRANT)


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
	check(si != null and si.remaining == 2, "burning arrives with its authored duration")
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


func _burn_ticks_and_expires() -> void:
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
		check(w.slot_at(1, 0, 0).find_status("burning") == null,
				"burning expires after its two round ticks")
		await cascade.resolve_event(&"turn_end")
		check_eq(def.current_shield, 1, "cold ground burns nobody")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the burn rounds resolve synchronously")


func _reattack_refreshes() -> void:
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var atk := _fire_unit(0)
	atk.row = 1
	atk.col = 3
	var arow: Array = w.player_grid[1]
	arow[3] = atk
	var def := _place(w, "pawn", 1, 1, 0)
	_attack(cascade, atk, def)
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"turn_end")
		done[0] = true
	chain.call()
	check(bool(done[0]), "the interim round resolves synchronously")
	var si := w.slot_at(1, 1, 0).find_status("burning")
	check(si != null and si.remaining == 1, "one round in, one round of fire left")
	_attack(cascade, atk, def)
	check(si != null and si.remaining == 2, "a fresh strike refreshes the fire to full")
