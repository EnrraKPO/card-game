extends TestCase

# Phase 3 of IMPLEMENTATION_PLAN.html — rules and flow. Pins computation: the condition
# families and routes, the trigger's structure and the generic parse driver with its
# mirror (Core §9), the resolver's two phases and five decisions (Core §4), the mutator
# roster (Mutation §4), the conductor's five-step run (Mutation §11), and the cascade's
# gather, ordering, holster, and depth-first firing (Mutation §9, §12). Exit: an event
# fired into a hand-built world runs authored effects end to end.


# A test-owned mutator that records each issuance — the conductor's walk made visible.
class RecorderMutator extends Mutator:
	var log: Array = []
	var unique: bool = false

	func _init(p_kind: StringName, p_log: Array, p_unique: bool = false) -> void:
		kind = p_kind
		log = p_log
		unique = p_unique

	func is_unique() -> bool:
		return unique

	func _issue(_plate: Plate, recipient: GameEntity) -> Array[Event]:
		log.append([kind, recipient])
		return []


# A test-owned picker with a scripted answer.
class TestPicker extends TargetPicker:
	var answer: GameEntity = null

	func pick(_candidates: Array[GameEntity], _plate: Plate) -> GameEntity:
		@warning_ignore("redundant_await")
		await null
		return answer


func suite_name() -> String:
	return "rules and flow (Phase 3)"


func run() -> void:
	_test_conditions()
	_test_trigger_routes()
	_test_trigger_folds()
	_test_parse_refusals()
	_test_roundtrip()
	await _test_decisions()
	await _test_conductor()
	await _test_cascade_end_to_end()
	await _test_depth_first()
	_test_implied_fielded()
	_test_turn_order()


func _fielded_unit(world: World, side: Side, address: Vector3i, speed: float = 1.0) -> Unit:
	var unit := Unit.new(side)
	unit.seed_stat(&"attack", 2.0)
	unit.seed_stat(&"health", 5.0)
	unit.seed_stat(&"speed", speed)
	WriteAuthority.mint(world, unit)
	var slot: Slot = world.board_manager.slot_at(address)
	WriteAuthority.insert(slot.get_container(&"slotted_unit"), unit)
	return unit


func _test_conditions() -> void:
	var world := World.new(1)
	var mine := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0))
	var theirs := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0))
	var occasion := Event.new(&"probe", mine, world.game)
	var plate := Plate.new(occasion, mine)

	check(IsHolderCondition.new().holds(plate, mine)
			and not IsHolderCondition.new().holds(plate, theirs), "is_holder")
	check(IsUnitCondition.new().holds(plate, mine)
			and not IsUnitCondition.new().holds(plate, world.game), "is_unit")
	check(IsAllyCondition.new().holds(plate, mine)
			and not IsAllyCondition.new().holds(plate, theirs)
			and not IsAllyCondition.new().holds(plate, world.game), "is_ally")
	check(IsEnemyCondition.new().holds(plate, theirs)
			and not IsEnemyCondition.new().holds(plate, mine)
			and not IsEnemyCondition.new().holds(plate, world.game), "is_enemy")

	MutationEngine.submit(StatusRequest.new(&"status", null, mine, &"poison", 1))
	var has := HasStatusCondition.new()
	has.status_id = &"poison"
	check(has.holds(plate, mine) and not has.holds(plate, theirs), "has_status")

	var status: Status = mine.get_container(&"contained").members[0] as Status
	var status_plate := Plate.new(occasion, status)
	check(HousesMeCondition.new().holds(status_plate, mine)
			and not HousesMeCondition.new().holds(status_plate, theirs), "houses_me")

	var named := NameIsCondition.new()
	named.role = &"ability"
	named.name = &"heal"
	check(not named.holds(plate, occasion), "name_is over an absent component is false")
	occasion.components.append(NameEventData.new(&"ability", &"heal"))
	check(named.holds(plate, occasion), "name_is finds its role and name")
	named.negate = true
	check(not named.holds(plate, occasion), "negate inverts the natural answer")
	occasion.components.clear()
	check(named.holds(plate, occasion), "over an absent component the inverted answer is true")

	var kinded := RequestKindIsCondition.new()
	kinded.name = &"poison"
	check(not kinded.holds(plate, occasion), "request_kind_is over an unstamped event is false")
	occasion.components.append(RequestEventData.new(
			DamageRequest.new(&"poison", mine, theirs, 1)))
	check(kinded.holds(plate, occasion), "request_kind_is reads the stamped request's kind")
	kinded.name = &"strike"
	check(not kinded.holds(plate, occasion), "a different kind does not answer")
	occasion.components.clear()


func _test_trigger_routes() -> void:
	var world := World.new(1)
	var mine := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0))
	var theirs := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0))
	var occasion := Event.new(&"probe", theirs, mine)

	var source_entry := Trigger.EntityEntry.new()
	source_entry.route = &"source"
	source_entry.conditions.append(IsEnemyCondition.new())
	check(source_entry.holds(Plate.new(occasion, mine)), "route source yields the occasion's source")

	var holder_entry := Trigger.EntityEntry.new()
	holder_entry.route = &"holder"
	holder_entry.conditions.append(IsHolderCondition.new())
	check(holder_entry.holds(Plate.new(occasion, mine)), "route holder yields the plate's holder")

	var target_entry := Trigger.EntityEntry.new()
	target_entry.route = &"target"
	target_entry.conditions.append(IsAllyCondition.new())
	check(target_entry.holds(Plate.new(occasion, mine)), "route target yields the occasion's target")
	var miss_entry := Trigger.EntityEntry.new()
	miss_entry.route = &"target"
	miss_entry.conditions.append(IsEnemyCondition.new())
	check(not miss_entry.holds(Plate.new(occasion, mine)),
			"the target route is the one target — nothing else answers")

	var world_entry := Trigger.EntityEntry.new()
	world_entry.route = &"world"
	world_entry.conditions.append(IsEnemyCondition.new())
	world_entry.conditions.append(IsUnitCondition.new())
	check(world_entry.holds(Plate.new(occasion, mine)), "route world reaches every entity")
	world_entry.negate = true
	check(not world_entry.holds(Plate.new(occasion, mine)),
			"the entry negate turns the existential claim universal")


func _test_trigger_folds() -> void:
	var world := World.new(1)
	var mine := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0))
	var occasion := Event.new(&"damaged", mine, mine)
	occasion.components.append(RequestEventData.new(
			DamageRequest.new(&"poison", mine, mine, 1)))
	var plate := Plate.new(occasion, mine)

	var trigger := Trigger.new()
	trigger.event = &"damaged"
	check(trigger.holds(plate), "empty lists hold vacuously")
	trigger.event = &"dodged"
	check(not trigger.holds(plate), "the axial event condition names the occasion")

	trigger.event = &"damaged"
	var wrong := RequestKindIsCondition.new()
	wrong.name = &"strike"
	var right := RequestKindIsCondition.new()
	right.name = &"poison"
	trigger.eventdata_conditions = [wrong, right]
	check(not trigger.holds(plate), "policy all needs every member")
	trigger.eventdata_policy = &"any"
	check(trigger.holds(plate), "policy any needs one")


func _test_parse_refusals() -> void:
	check(MarkupParse.parse_condition({"kind": "no_such_kind"}) == null, "unknown kind refused")
	check(MarkupParse.parse_condition({"kind": "has_status", "surprise": 1}) == null,
			"a stranger member is refused")
	check(MarkupParse.parse_condition({"kind": "has_status", "status_id": 4}) == null,
			"a type mismatch is refused")
	check(MarkupParse.parse_trigger({"eventdata_conditions": {}}) == null,
			"a trigger without its event is refused")
	check(MarkupParse.parse_trigger({"event": "damaged", "gate": {}}) == null,
			"a stranger trigger key is refused")
	check(MarkupParse.parse_trigger({"event": "died", "eventdata_conditions":
			{"conditions": [{"kind": "is_holder"}]}}) == null,
			"an entity kind in the eventdata list is refused")
	check(MarkupParse.parse_payload([{"stat_mutation": {"stat": "speed"}}]).is_empty(),
			"a mutator entry omitting a required parameter fails parse")
	check(MarkupParse.parse_payload(["stat_mutation"]).is_empty(),
			"the bare-string form is refused where parameters exist")
	check(MarkupParse.parse_effect({"targeting": {"decision": "nearest"}}) == null,
			"an effect without a trigger is refused")
	check(MarkupParse.parse_targeting({"conditions": []}) == null,
			"authored targeting without a decision is refused")


func _test_roundtrip() -> void:
	var markup: Dictionary = {
		"trigger": {
			"event": "damaged",
			"eventdata_conditions": {"policy": "any", "conditions": [
				{"kind": "request_kind_is", "name": "poison"},
			]},
			"entity_conditions": {"entries": [
				{"route": "source", "conditions": [{"kind": "is_holder"}]},
				{"route": "world", "negate": true, "conditions": [
					{"kind": "is_enemy"}, {"kind": "is_unit", "negate": true},
				]},
			]},
		},
		"targeting": {"decision": {"stat_ranked": {"stat": "health", "rank": "lowest"}},
				"conditions": [{"kind": "is_ally"}, {"kind": "is_unit"}]},
		"payload": ["strike", {"stat_mutation": {"stat": "speed", "delta": 3}},
				{"draw": {"count": 1}}, {"status": {"id": "poison", "stacks": 2}},
				{"damage": {"amount": 4}}],
		"windup": "lunge",
	}
	var effect: Effect = MarkupParse.parse_effect(markup)
	check(effect != null, "the full authored form parses")
	if effect == null:
		return
	var mirrored: Dictionary = MarkupParse.serialize_effect(effect)
	var again: Effect = MarkupParse.parse_effect(mirrored)
	check(again != null and MarkupParse.serialize_effect(again) == mirrored,
			"serialization is the mirror walk — the roundtrip is stable")
	check_eq(effect.payload.size(), 5, "every payload entry parsed")
	check(effect.payload[0].kind == &"strike" and (effect.payload[1] as StatMutationMutator).delta == 3,
			"typed members land in their real types")


func _test_decisions() -> void:
	var world := World.new(11)
	var holder := _fielded_unit(world, world.player_side(), Vector3i(0, 1, 3))
	var near := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 0))
	var far := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 3))
	far.seed_stat(&"health", 9.0)
	var occasion := Event.new(&"probe", holder, world.game)
	var plate := Plate.new(occasion, holder)
	var enemies: Array[EntityCondition] = []
	enemies.append(IsEnemyCondition.new())
	enemies.append(IsUnitCondition.new())

	var nearest := TargetResolver.new(enemies, NearestDecision.new())
	check_eq(nearest.resolve(plate), [near] as Array[GameEntity], "nearest elects by the distance")
	check_eq(await nearest.engage(plate), [near] as Array[GameEntity],
			"a deterministic decision engages from its resolution")

	var ranked_decision := StatRankedDecision.new()
	ranked_decision.stat = &"health"
	ranked_decision.rank = &"highest"
	var ranked := TargetResolver.new(enemies, ranked_decision)
	check_eq(ranked.resolve(plate), [far] as Array[GameEntity], "stat-ranked elects the extreme bearer")

	var random := TargetResolver.new(enemies, RandomDecision.new())
	check_eq(random.resolve(plate).size(), 2, "random resolves to the eligible field, undecided")
	var drawn: Array[GameEntity] = await random.engage(plate)
	check(drawn.size() == 1 and (drawn[0] == near or drawn[0] == far),
			"random engages one of the field from the seeded rng")

	var picked := TargetResolver.new(enemies, HandPickDecision.new())
	check_eq(picked.resolve(plate).size(), 2, "hand-pick resolves to the eligible field, undecided")
	check((await picked.engage(plate)).is_empty(), "a declined pick yields an empty election")
	var picker := TestPicker.new()
	picker.answer = far
	world.picker = picker
	check_eq(await picked.engage(plate), [far] as Array[GameEntity], "the picker's pick is the election")

	var carrying := Event.new(&"play_engaged", holder, near)
	var stock := TargetResolver.new(enemies, OccasionsTargetDecision.new())
	check_eq(stock.resolve(Plate.new(carrying, holder)), [near] as Array[GameEntity],
			"the stock form takes the occasion's target as its own")
	var outside := Event.new(&"play_engaged", holder, holder)
	check(stock.resolve(Plate.new(outside, holder)).is_empty(),
			"a carried target outside the narrowed field is not elected")

	var game_default := TargetResolver.game_default()
	check_eq(game_default.resolve(plate), [world.game] as Array[GameEntity],
			"the Card type fact: automatic targeting of the Game")

	# The no-targeting fallback (Core §4, A16): the AutoResolver elects the target
	# carried in context, falling back to the Game where none is found.
	var fallback := Effect.new(Trigger.new(), null, [] as Array[Mutator])
	check(fallback.resolver is AutoResolver, "no targeting authored: the AutoResolver")
	var carried := Event.new(&"probe", holder, near)
	check_eq(fallback.resolver.resolve(Plate.new(carried, holder)),
			[near] as Array[GameEntity], "the AutoResolver resolves as the carried target")
	var bare := Event.new(&"probe", holder, null)
	check_eq(fallback.resolver.resolve(Plate.new(bare, holder)),
			[world.game] as Array[GameEntity], "no target found: the Game")


func _test_conductor() -> void:
	var world := World.new(3)
	var holder := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0))
	var a := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0))
	var b := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 0))
	var log: Array = []
	var enemies: Array[EntityCondition] = []
	enemies.append(IsEnemyCondition.new())
	enemies.append(IsUnitCondition.new())
	var payload: Array[Mutator] = []
	payload.append(RecorderMutator.new(&"first", log))
	payload.append(RecorderMutator.new(&"opening", log, true))
	payload.append(RecorderMutator.new(&"second", log))
	var trigger := Trigger.new()
	trigger.event = &"probe"
	# Two recipients: every enemy unit, through the all decision.
	var effect := Effect.new(trigger,
			TargetResolver.new(enemies, AllDecision.new()), payload)
	var occasion := Event.new(&"probe", holder, world.game)
	var conductor := EffectConductor.new(world)
	var holster: Array[Event] = []
	await conductor.run(effect, Plate.new(occasion, holder), holster)
	check_eq(log.size(), 5, "one unique issuance plus two mutators × two recipients")
	check(log[0][0] == &"opening" and log[0][1] == null,
			"unique mutators run first, once, recipient null")
	check(log[1][0] == &"first" and log[1][1] == a and log[2][0] == &"first" and log[2][1] == b,
			"each mutator speaks its full ask across all recipients")
	check(log[3][0] == &"second" and log[4][0] == &"second",
			"the payload list is the authored sequence")

	log.clear()
	var nobody := Trigger.new()
	nobody.event = &"probe"
	var empty_conditions: Array[EntityCondition] = []
	empty_conditions.append(IsEnemyCondition.new())
	empty_conditions.append(IsHolderCondition.new())
	var never := Effect.new(nobody, TargetResolver.new(empty_conditions, NearestDecision.new()),
			payload)
	await conductor.run(never, Plate.new(occasion, holder), holster)
	check(log.is_empty(), "an empty election ends the delivery — nothing delivered")


func _test_cascade_end_to_end() -> void:
	var world := World.new(5)
	var avenger := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0))
	var brother := _fielded_unit(world, world.player_side(), Vector3i(0, 1, 0))
	var foe := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0))
	# The Avenger's rule, authored in the bible's markup: when an allied unit dies, its
	# attack rises.
	var effect: Effect = MarkupParse.parse_effect({
		"trigger": {"event": "died", "entity_conditions": {"entries": [
			{"route": "target", "conditions": [{"kind": "is_ally"}, {"kind": "is_unit"}]},
		]}},
		"targeting": {"decision": "nearest", "conditions": [{"kind": "is_holder"}]},
		"payload": [{"stat_mutation": {"stat": "attack", "delta": 2}}],
	})
	check(effect != null, "the authored rule parses")
	avenger.effects.append(effect)

	var events: Array[Event] = MutationEngine.submit(
			DamageRequest.new(&"test", null, brother, 9))
	check_eq(events.size(), 2, "the lethal blow returns damaged and died")
	await world.cascade.fire(events[1])
	check_eq(avenger.get_stat(&"attack"), 4.0, "an allied death raises the attack — end to end")

	var enemy_death: Array[Event] = MutationEngine.submit(
			DamageRequest.new(&"test", null, foe, 9))
	await world.cascade.fire(enemy_death[1])
	check_eq(avenger.get_stat(&"attack"), 4.0, "an enemy death does not engage the rule")


func _test_depth_first() -> void:
	var world := World.new(5)
	var avenger := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0))
	var frail := _fielded_unit(world, world.player_side(), Vector3i(0, 1, 0))
	frail.seed_stat(&"health", 1.0)
	var martyr := _fielded_unit(world, world.player_side(), Vector3i(0, 2, 0))
	# The martyr's death damages the frail ally lethally; the frail one's death is a
	# fresh event fired depth-first, and the avenger's rule reacts to both deaths.
	var avenge: Effect = MarkupParse.parse_effect({
		"trigger": {"event": "died", "entity_conditions": {"entries": [
			{"route": "target", "conditions": [{"kind": "is_ally"}, {"kind": "is_unit"}]},
		]}},
		"targeting": {"decision": "nearest", "conditions": [{"kind": "is_holder"}]},
		"payload": [{"stat_mutation": {"stat": "attack", "delta": 2}}],
	})
	var lash: Effect = MarkupParse.parse_effect({
		"trigger": {"event": "died", "entity_conditions": {"entries": [
			{"route": "target", "conditions": [{"kind": "is_holder"}]},
		]}},
		"targeting": {"decision": {"stat_ranked": {"stat": "health", "rank": "lowest"}},
				"conditions": [{"kind": "is_ally"}, {"kind": "is_unit"},
						{"kind": "is_holder", "negate": true}]},
		"payload": [{"damage": {"amount": 3}}],
	})
	# The martyr's built-in burial reacts to its death ahead of lash (same holder,
	# machinery first), so at lash's moment the martyr stands in the graveyard — the
	# implied fielded condition must be removed for a die-reaction to fire (Mutation §2's
	# removable default; the authored syntax is out of frame, the machinery member serves).
	lash.fielded_condition_removed = true
	avenger.effects.append(avenge)
	martyr.effects.append(lash)

	var events: Array[Event] = MutationEngine.submit(
			DamageRequest.new(&"test", null, martyr, 9))
	await world.cascade.fire(events[1])
	check(frail.get_stat(&"health") <= 0.0, "the martyr's reaction dealt its lethal lash")
	check_eq(avenger.get_stat(&"attack"), 6.0,
			"both allied deaths reached the avenger — the chain unfolded depth-first")


func _test_implied_fielded() -> void:
	var world := World.new(9)
	var side: Side = world.player_side()
	var carded := Unit.new(side)
	carded.seed_stat(&"attack", 1.0)
	WriteAuthority.mint(world, carded)
	WriteAuthority.insert(side.get_container(&"hand"), carded)
	var trigger := Trigger.new()
	trigger.event = &"probe"
	var log: Array = []
	var payload: Array[Mutator] = []
	payload.append(RecorderMutator.new(&"mark", log))
	var rule := Effect.new(trigger, null, payload)
	carded.effects.append(rule)

	await world.cascade.fire(Event.new(&"probe", world.game, world.game))
	check(log.is_empty(), "a non-fielded unit's effects do not fire")

	rule.fielded_condition_removed = true
	await world.cascade.fire(Event.new(&"probe", world.game, world.game))
	check_eq(log.size(), 1, "the removed condition frees the hand card's effect")

	log.clear()
	rule.fielded_condition_removed = false
	var relic := Relic.new(side)
	WriteAuthority.mint(world, relic)
	WriteAuthority.insert(side.get_container(&"relics"), relic)
	relic.effects.append(rule)
	await world.cascade.fire(Event.new(&"probe", world.game, world.game))
	check_eq(log.size(), 1, "the condition binds units; other holders are untouched")


func _test_turn_order() -> void:
	var world := World.new(2)
	var slow_front := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 3), 1.0)
	var fast_back := _fielded_unit(world, world.player_side(), Vector3i(0, 2, 0), 3.0)
	var enemy_fast := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0), 3.0)
	var enemy_deep := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 2), 1.0)
	var high_row := _fielded_unit(world, world.player_side(), Vector3i(0, 2, 3), 1.0)
	var order: Array[Unit] = CombatCascade.turn_order(world)
	check_eq(order, [fast_back, enemy_fast, high_row, slow_front, enemy_deep] as Array[Unit],
			"speed desc, player on ties, forward depth, then row — the pre-nuke ordering")