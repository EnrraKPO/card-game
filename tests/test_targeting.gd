extends TestCase

# The target-resolver system: effects hold an injected TargetResolver that alone decides
# who is affected, from the same shared context the trigger saw (event, holder, board).
# Covers the legacy policy mapping (zero-migration), each kind's resolution, native-form
# parsing/round-trip, and end-to-end dispatch with participant targeting.


func suite_name() -> String:
	return "Target resolvers"


func run() -> void:
	_legacy_mapping()
	_all_and_conditions()
	_auto_nearest_and_random()
	_column_priority()
	_participant()
	_manual()
	_native_round_trip()
	_dispatch_participant()


# A unit with no place on any board — where it stands is the board's business, and these
# fixtures hand it over to one below.
func _unit(atk: int, owner: int, pieces: Array = ["pawn"]) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_tgt_test", "display_name": "T",
		"cost": 1, "attack": atk, "health": 5, "speed": 1, "chess_pieces": pieces,
	}))
	inst.owner = owner
	return inst


# A world with each side's units standing along its back row, one per column in list order
# (nulls leave a gap) — the same shape the old explicit single-row grids described, now
# expressed as placement because placement is where it lives.
func _ctx(holder: CardInstance, player_units: Array, enemy_units: Array) -> EffectContext:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	for i in player_units.size():
		var pu := player_units[i] as CardInstance
		if pu != null:
			w.place_unit(pu, 0, i, 0)
	for i in enemy_units.size():
		var eu := enemy_units[i] as CardInstance
		if eu != null:
			w.place_unit(eu, 0, i, 1)
	return w.make_context(holder)


func _legacy_mapping() -> void:
	var checks := [
		["self", "on_play", TargetResolver.Participant],
		["single_nearest", "on_play", TargetResolver.Auto],
		["single_random", "on_play", TargetResolver.Auto],
		["all_enemies", "on_play", TargetResolver.All],
		["all_allies", "on_play", TargetResolver.All],
		["all", "on_play", TargetResolver.All],
		["manual", "on_play", TargetResolver.Manual],
		["manual_slot", "on_play", TargetResolver.ManualSlot],
		["attack_target", "on_attack", TargetResolver.Participant],
		["attacker", "on_damage_taken", TargetResolver.Participant],
	]
	for row: Array in checks:
		var e := Effect.from_dict({"trigger": row[1], "targeting_policy": row[0],
				"attribute": "attack", "amount": 1})
		check(is_instance_of(e.targets_resolver(), row[2]),
				"legacy %s maps to the right resolver kind" % row[0])
	# legacy `subject` follows the trigger: origin normally, destination for on_damage_taken
	var es := Effect.from_dict({"trigger": "on_attack", "targeting_policy": "subject",
			"attribute": "attack", "amount": 1})
	check((es.targets_resolver() as TargetResolver.Participant).participant == "origin",
			"legacy subject on on_attack is the origin")
	var ed := Effect.from_dict({"trigger": "on_damage_taken", "targeting_policy": "subject",
			"attribute": "attack", "amount": 1})
	check((ed.targets_resolver() as TargetResolver.Participant).participant == "destination",
			"legacy subject on on_damage_taken is the destination")


func _all_and_conditions() -> void:
	var holder := _unit(2, 0)
	var ally := _unit(2, 0)
	var enemy := _unit(2, 1)
	var ctx := _ctx(holder, [holder, ally], [enemy])

	var e := Effect.from_dict({"trigger": "on_play", "targeting_policy": "all_allies",
			"attribute": "attack", "amount": 1})
	var targets := e.targets_resolver().resolve(null, holder, ctx)
	check_eq(targets.size(), 2, "all_allies resolves both friendly units")
	check(targets.has(holder) and targets.has(ally), "…including the holder")

	var ee := Effect.from_dict({"trigger": "on_play", "targeting_policy": "all_enemies",
			"attribute": "damage_taken", "amount": 1,
			"conditions": [{"attribute": "attack", "comparator": "gte", "value": 5}]})
	check(ee.targets_resolver().resolve(null, holder, ctx).is_empty(),
			"authored conditions still gate on top of the implicit enemy scope")

	# native All with a composition condition — "every pawn on the board"
	var en := Effect.from_dict({"trigger": "on_play",
			"targets": {"kind": "all", "conditions": [{"composition": ["pawn"]}]},
			"attribute": "attack", "amount": 1})
	check_eq(en.targets_resolver().resolve(null, holder, ctx).size(), 3,
			"native All spans BOTH sides when no relation gates it")


func _auto_nearest_and_random() -> void:
	var holder := _unit(2, 0)
	var near_enemy := _unit(2, 1)
	var far_enemy := _unit(2, 1)
	var ctx := _ctx(holder, [holder], [near_enemy, null, far_enemy])

	var e := Effect.from_dict({"trigger": "on_play", "targeting_policy": "single_nearest",
			"attribute": "damage_taken", "amount": 1})
	var targets := e.targets_resolver().resolve(null, holder, ctx)
	check_eq(targets.size(), 1, "single_nearest yields one unit")
	check(targets[0] == near_enemy, "…the closest enemy")

	var er := Effect.from_dict({"trigger": "on_play", "targeting_policy": "single_random",
			"attribute": "damage_taken", "amount": 1})
	var rt := er.targets_resolver().resolve(null, holder, ctx)
	check(rt.size() == 1 and rt[0].owner == 1, "single_random picks one enemy")

	# native Auto: nearest ALLY — inexpressible before this refactor. The candidates are WOUNDED
	# because the payload is a heal, and a heal cannot reach anyone at full health (the implicit
	# viability condition — see EffectCondition); this case is about the auto search, not that rule.
	var ally_near := _unit(2, 0)
	ally_near.current_health -= 2
	holder.current_health -= 2
	var ctx2 := _ctx(holder, [holder, ally_near], [near_enemy])
	var ea := Effect.from_dict({"trigger": "on_play",
			"targets": {"kind": "auto", "criterion": "nearest",
				"conditions": [{"relation": "ally"}, {"attribute": "attack", "comparator": "gte", "value": 0}]},
			"attribute": "health", "amount": 1})
	var at := ea.targets_resolver().resolve(null, holder, ctx2)
	check(at.size() == 1 and at[0] == holder, "native Auto(nearest, ally) works — holder is distance 0")

	# native Auto with count
	var ec := Effect.from_dict({"trigger": "on_play",
			"targets": {"kind": "auto", "criterion": "nearest", "count": 2,
				"conditions": [{"relation": "enemy"}]},
			"attribute": "damage_taken", "amount": 1})
	check_eq(ec.targets_resolver().resolve(null, holder, ctx).size(), 2,
			"native Auto count=2 returns the two nearest enemies")


# Column depth DOMINATES lane offset (the user-observed bug: equal weighting let a
# same-lane unit two columns deep tie an adjacent-lane front unit, and the unstable
# sort then read as "units prefer their own row"). Within one column the facing lane
# wins; exact ties break deterministically by row index. Attack targeting
# (TargetingStrategy.dist) and effect targeting (TargetResolver.board_distance) must
# agree on this geometry.
func _column_priority() -> void:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	var attacker := _unit(2, 0)
	var same_lane_deep := _unit(2, 1)
	var adjacent_front := _unit(2, 1)
	w.place_unit(attacker, 1, 3, 0)        # player: front column, middle lane
	w.place_unit(same_lane_deep, 1, 1, 1)  # faces the attacker, two columns deep
	w.place_unit(adjacent_front, 0, 0, 1)  # one lane over, front column

	var strat := TargetingNearest.new()
	check(strat.find_target(w.locations, attacker) == adjacent_front,
			"attack targeting: closest COLUMN beats a same-lane deeper target")

	var facing := _unit(2, 1)               # front column, facing lane
	w.place_unit(facing, 1, 0, 1)
	check(strat.find_target(w.locations, attacker) == facing,
			"attack targeting: within the closest column the facing lane wins")
	w.locations.undock(facing)

	var lane_two := _unit(2, 1)             # front column, one lane over (the other way)
	w.place_unit(lane_two, 2, 0, 1)
	check(strat.find_target(w.locations, attacker) == adjacent_front,
			"attack targeting: equal lane offsets break deterministically by row")
	w.locations.undock(lane_two)

	# effect targeting shares the geometry — one placement, both readings
	var e := Effect.from_dict({"trigger": "on_play", "targeting_policy": "single_nearest",
			"attribute": "damage_taken", "amount": 1})
	var targets := e.targets_resolver().resolve(null, attacker, w.make_context(attacker))
	check(targets.size() == 1 and targets[0] == adjacent_front,
			"effect targeting: single_nearest agrees — closest column first")


func _participant() -> void:
	var holder := _unit(2, 0)
	var striker := _unit(3, 1)
	var struck := _unit(2, 0)
	var ctx := _ctx(holder, [holder, struck], [striker])
	var ev := GameEvent.make(&"struck", striker, struck)

	var e := Effect.from_dict({"trigger": "on_damage_taken", "targeting_policy": "attacker",
			"status": {"id": "blind", "stacks": 1}})
	var targets := e.targets_resolver().resolve(ev, holder, ctx)
	check(targets.size() == 1 and targets[0] == striker, "participant(origin) returns the striker")

	# no event (transient use) → participant targeting yields nothing, by construction
	check(e.targets_resolver().resolve(null, holder, ctx).is_empty(),
			"participant targeting without an event yields no targets")

	# simple event has no destination
	var ep := Effect.from_dict({"trigger": "on_attack", "targeting_policy": "attack_target",
			"attribute": "damage_taken", "amount": 1})
	check(ep.targets_resolver().resolve(GameEvent.make(&"death", striker), holder, ctx).is_empty(),
			"participant(destination) on a destination-less event yields nothing")

	# holder participant needs no event at all
	var eh := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "attack", "amount": 1})
	var ht := eh.targets_resolver().resolve(null, holder, ctx)
	check(ht.size() == 1 and ht[0] == holder, "participant(holder) resolves without an event")


func _manual() -> void:
	var holder := _unit(2, 0)
	var picked := _unit(2, 0)
	picked.current_health -= 2   # the payload below is a heal; a whole unit is no target for one
	var ctx := _ctx(holder, [holder, picked], [])
	var e := Effect.from_dict({"trigger": "on_play", "targeting_policy": "manual",
			"attribute": "health", "amount": 2,
			"conditions": [{"attribute": "attack", "comparator": "lte", "value": 5}]})
	check(e.targets_resolver().resolve(null, holder, ctx).is_empty(), "manual without a pick yields nothing")
	ctx.manual_target = picked
	var targets := e.targets_resolver().resolve(null, holder, ctx)
	check(targets.size() == 1 and targets[0] == picked, "manual resolves the picked unit")
	# conditions gate the pick too
	var strict := Effect.from_dict({"trigger": "on_play", "targeting_policy": "manual",
			"attribute": "health", "amount": 2,
			"conditions": [{"attribute": "attack", "comparator": "gte", "value": 99}]})
	check(strict.targets_resolver().resolve(null, holder, ctx).is_empty(), "manual pick is condition-gated")


func _native_round_trip() -> void:
	var native := {"trigger": {"kind": "event", "event": "death", "conditions": [{"relation": "ally"}]},
			"targets": {"kind": "auto", "criterion": "nearest", "count": 2, "conditions": [{"relation": "enemy"}]},
			"attribute": "damage_taken", "amount": 2}
	var d := Effect.from_dict(native).to_dict()
	var tv: Variant = d.get("targets")
	check(tv is Dictionary and str((tv as Dictionary).get("kind")) == "auto"
			and int((tv as Dictionary).get("count")) == 2,
			"native targets round-trip as a dictionary")
	check(not d.has("targeting_policy") and not d.has("conditions"),
			"native form carries no legacy targeting keys")
	var reparsed := Effect.from_dict(d)
	check(reparsed.targets_resolver() is TargetResolver.Auto, "re-parsed native resolver keeps its kind")
	check(reparsed.targeting_policy == Effect.TargetingPolicy.SINGLE_NEAREST,
			"native form derives the compat policy enum")

	# legacy stays byte-shaped: policy string + top-level conditions
	var legacy := Effect.from_dict({"trigger": "on_play", "targeting_policy": "all_enemies",
			"attribute": "damage_taken", "amount": 2,
			"conditions": [{"attribute": "speed", "comparator": "gte", "value": 5}]}).to_dict()
	check(str(legacy.get("targeting_policy")) == "all_enemies" and (legacy.get("conditions") as Array).size() == 1
			and not legacy.has("targets"),
			"legacy targeting schema round-trips unchanged")


func _dispatch_participant() -> void:
	# End-to-end: "when this unit is struck, blind the origin" — through trigger dispatch,
	# with the target resolver reading the event's origin.
	var holder := CardInstance.from_data(CardData.build_from_dict({
		"id": "_spiky", "display_name": "S", "cost": 1, "attack": 2, "health": 9, "speed": 1,
		"effects": [{
			"trigger": {"kind": "dual_event", "event": "struck",
				"destination_conditions": [{"relation": "self"}]},
			"targets": {"kind": "participant", "participant": "origin"},
			"status": {"id": "blind", "stacks": 1},
		}],
	}))
	holder.owner = 0
	var striker := _unit(3, 1)
	var ctx := _ctx(holder, [holder], [striker])
	var ev := GameEvent.make(&"struck", striker, holder)
	var res := EffectSystem.trigger(ev, holder, ctx)
	check(not res.is_empty(), "struck dispatch produced a result")
	check(striker.find_status("blind") != null, "the ORIGIN (striker) got blinded via participant targeting")
