extends TestCase

# Phase 2 of IMPLEMENTATION_PLAN.html — the write road. Pins computation: the
# EngineRequest family resolved through MutationEngine.submit into committed writes and
# returned events (Mutation §6–§8) — the six procedures, the strike mechanics with their
# seeded Game stats, and the authority's fact events, died among them.


func suite_name() -> String:
	return "write road (Phase 2)"


func run() -> void:
	_test_stat_mutation()
	_test_died()
	_test_damage()
	_test_strike_plain()
	_test_strike_dodge()
	_test_strike_crit()
	_test_chance_formula()
	_test_status()
	_test_container_move()
	_test_pay_cost()
	_test_refusals()


# A fielded unit in a fresh world: minted, stats seeded, housed on the given slot.
func _fielded_unit(world: World, side: Side, address: Vector3i, attack: float,
		health: float, speed: float, shield: float) -> Unit:
	var unit := Unit.new(side)
	unit.seed_stat(&"attack", attack)
	unit.seed_stat(&"health", health)
	unit.seed_stat(&"speed", speed)
	unit.seed_stat(&"shield", shield)
	WriteAuthority.mint(world, unit)
	var slot: Slot = world.board_manager.slot_at(address)
	WriteAuthority.insert(slot.get_container(&"slotted_unit"), unit)
	return unit


func _test_stat_mutation() -> void:
	var world := World.new(1)
	var unit := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0), 2.0, 5.0, 1.0, 0.0)
	var events: Array[Event] = MutationEngine.submit(
			StatMutationRequest.new(&"stat_mutation", unit, unit, &"attack", 3))
	check_eq(unit.get_stat(&"attack"), 5.0, "the delta is applied")
	check(events.is_empty(), "a plain stat change bears no event yet")
	MutationEngine.submit(StatMutationRequest.new(&"stat_mutation", unit, unit, &"attack", -2))
	check_eq(unit.get_stat(&"attack"), 3.0, "a negative delta applies the same road")


func _test_died() -> void:
	var world := World.new(1)
	var unit := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0), 2.0, 3.0, 1.0, 0.0)
	var killer := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0), 2.0, 3.0, 1.0, 0.0)
	var ask := StatMutationRequest.new(&"poison", killer, unit, &"health", -3)
	var events: Array[Event] = MutationEngine.submit(ask)
	check_eq(events.size(), 1, "health reaching zero produces one event")
	check(events[0].name == &"died" and events[0].source == killer,
			"died, source the request's source (A15)")
	var stamps: Array[EventData] = events[0].components_of(RequestEventData)
	check(stamps.size() == 1 and (stamps[0] as RequestEventData).request == ask
			and (stamps[0] as RequestEventData).request.mutator_kind == &"poison",
			"died carries the request at hand (A19)")
	check(events[0].target == unit, "died carries the dead unit as its native target (A16)")
	var again: Array[Event] = MutationEngine.submit(
			StatMutationRequest.new(&"poison", killer, unit, &"health", -1))
	check(again.is_empty(), "died is the crossing, not every write below zero")


func _test_damage() -> void:
	var world := World.new(1)
	var unit := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0), 2.0, 4.0, 1.0, 5.0)

	var dealer := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0), 2.0, 4.0, 1.0, 0.0)
	var ask := DamageRequest.new(&"damage", dealer, unit, 3)
	var absorbed: Array[Event] = MutationEngine.submit(ask)
	check(unit.get_stat(&"shield") == 2.0 and unit.get_stat(&"health") == 4.0,
			"shield absorbs first")
	check_eq(absorbed.size(), 1, "an absorbed hit returns the damaged event alone")
	check_eq(absorbed[0].name, &"damaged", "the damaged event names the happening")
	check(absorbed[0].source == dealer, "damaged, source the request's source (A15)")
	var absorbed_stamps: Array[EventData] = absorbed[0].components_of(RequestEventData)
	check(absorbed_stamps.size() == 1
			and (absorbed_stamps[0] as RequestEventData).request == ask,
			"damaged carries the request at hand (A19)")
	check(absorbed[0].target == unit,
			"damaged carries the damaged unit as its native target (A16)")
	var facts: Array[EventData] = absorbed[0].components_of(StatMutationEventData)
	check(facts.size() == 1 and (facts[0] as StatMutationEventData).stat == &"shield"
			and (facts[0] as StatMutationEventData).delta == -3,
			"the damaged event carries the shield write")

	var through: Array[Event] = MutationEngine.submit(
			DamageRequest.new(&"damage", null, unit, 5))
	check(unit.get_stat(&"shield") == 0.0 and unit.get_stat(&"health") == 1.0,
			"the remainder lands on health")
	var through_facts: Array[EventData] = through[0].components_of(StatMutationEventData)
	check_eq(through_facts.size(), 2, "a piercing hit carries both writes")

	var lethal: Array[Event] = MutationEngine.submit(
			DamageRequest.new(&"damage", null, unit, 4))
	check_eq(lethal.size(), 2, "a lethal hit returns damaged and died")
	check(lethal[0].name == &"damaged" and lethal[1].name == &"died",
			"damaged precedes died in return order")


func _test_strike_plain() -> void:
	var world := World.new(7)
	world.game.seed_stat(&"crit_base", 0.0)
	var striker := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 3), 4.0, 10.0, 0.0, 0.0)
	var defender := _fielded_unit(world, world.enemy_side(), Vector3i(1, 2, 0), 1.0, 10.0, 0.0, 0.0)
	var events: Array[Event] = MutationEngine.submit(StrikeRequest.new(&"strike", striker, defender))
	check_eq(defender.get_stat(&"health"), 6.0, "the amount is read from the striker's attack")
	check(events.size() == 1 and events[0].name == &"damaged",
			"speed zero and crit base zero: the strike connects plainly")


func _test_strike_dodge() -> void:
	var world := World.new(7)
	world.game.seed_stat(&"dodge_base", 100.0)
	world.game.seed_stat(&"dodge_cap", 100.0)
	var striker := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 3), 4.0, 10.0, 0.0, 0.0)
	var defender := _fielded_unit(world, world.enemy_side(), Vector3i(1, 2, 0), 1.0, 10.0, 0.0, 0.0)
	var events: Array[Event] = MutationEngine.submit(StrikeRequest.new(&"strike", striker, defender))
	check_eq(defender.get_stat(&"health"), 10.0, "a dodge ends the strike — no damage")
	check(events.size() == 1 and events[0].name == &"dodged" and events[0].source == striker,
			"the dodged event, source the request's source (A15)")
	check(events[0].target == defender,
			"dodged carries the dodger as its native target (A16)")

	var tower := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 0), 0.0, 10.0, 0.0, 0.0)
	tower.is_building = true
	MutationEngine.submit(StrikeRequest.new(&"strike", striker, tower))
	check_eq(tower.get_stat(&"health"), 6.0, "buildings never dodge")


func _test_strike_crit() -> void:
	var world := World.new(7)
	world.game.seed_stat(&"crit_base", 100.0)
	world.game.seed_stat(&"crit_cap", 100.0)
	var striker := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 3), 4.0, 10.0, 0.0, 0.0)
	var defender := _fielded_unit(world, world.enemy_side(), Vector3i(1, 2, 0), 1.0, 20.0, 0.0, 0.0)
	var events: Array[Event] = MutationEngine.submit(StrikeRequest.new(&"strike", striker, defender))
	check_eq(defender.get_stat(&"health"), 12.0, "the crit multiplies the damage (×2.0)")
	check(events[0].name == &"crit" and events[0].source == striker,
			"the crit event, source the striker")

	# Crit rolls only when the damage after mitigation is above zero.
	var walled := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 0), 1.0, 10.0, 0.0, 4.0)
	var wall_events: Array[Event] = MutationEngine.submit(
			StrikeRequest.new(&"strike", striker, walled))
	check(walled.get_stat(&"shield") == 0.0 and walled.get_stat(&"health") == 10.0,
			"the shield would absorb it whole: no crit rolls")
	check_eq(wall_events[0].name, &"damaged", "the walled strike returns damaged alone")

	# The multiplier is capped by its cap stat.
	world.game.seed_stat(&"crit_multiplier", 7.0)
	var soft := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0), 1.0, 30.0, 0.0, 0.0)
	MutationEngine.submit(StrikeRequest.new(&"strike", striker, soft))
	check_eq(soft.get_stat(&"health"), 10.0, "the multiplier caps at ×5.0")


func _test_chance_formula() -> void:
	check_eq(StrikeProcedure.chance(0.0, 10.0, 1.0, 4.0, 5.0, 75.0), 30.0,
			"base + speed×rating + difference×rating")
	check_eq(StrikeProcedure.chance(0.0, 10.0, 1.0, 4.0, -5.0, 75.0), 10.0,
			"the difference term is one-sided")
	check_eq(StrikeProcedure.chance(50.0, 30.0, 1.0, 4.0, 20.0, 75.0), 75.0,
			"the cap bounds the chance")


func _test_status() -> void:
	var world := World.new(1)
	var unit := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0), 1.0, 5.0, 1.0, 0.0)
	MutationEngine.submit(StatusRequest.new(&"status", null, unit, &"poison", 2))
	var contained: EntityContainer = unit.get_container(&"contained")
	check_eq(contained.members.size(), 1, "the status is minted and inserted")
	var status := contained.members[0] as Status
	check(status != null and status.status_id == &"poison", "a Status of the asked id")
	check_eq(status.get_stat(&"stacks"), 2.0, "the grant's stacks seed it")
	check(status.world == world and status.housing == contained,
			"minted into the world, housed in `contained`")

	MutationEngine.submit(StatusRequest.new(&"status", null, unit, &"poison", 3))
	check_eq(contained.members.size(), 1, "a carried status is not minted twice")
	check_eq(status.get_stat(&"stacks"), 5.0, "the stacks are added")


func _test_container_move() -> void:
	var world := World.new(1)
	var side: Side = world.player_side()
	var card := Unit.new(side)
	WriteAuthority.mint(world, card)
	WriteAuthority.insert(side.get_container(&"deck"), card)

	# The moved entity as target routes to its specific-purpose procedure (A17).
	var draw: Array[Event] = MutationEngine.submit(DrawRequest.new(&"draw", side, card))
	check(card.housing == side.get_container(&"hand"),
			"the draw moves the target from its deck to its side's hand")
	check(draw.is_empty(), "a deck-to-hand move bears no event yet")

	# A move op elects the destination as target; the mutator introduces the cargo (A17).
	var slot: Slot = world.board_manager.slot_at(Vector3i(0, 1, 1))
	var arrival: Array[Event] = MutationEngine.submit(
			MoveRequest.new(&"placement", card, slot, card, &"slotted_unit"))
	check(card.housing == slot.get_container(&"slotted_unit"), "the unit stands on the slot")
	check(arrival.is_empty(), "at this scope no arrival event exists (T2)")

	var bury: Array[Event] = MutationEngine.submit(BuryRequest.new(&"bury", card, card))
	check(card.housing == side.get_container(&"graveyard"),
			"the bury places the target in its side's graveyard")
	check(bury.is_empty(), "a burial bears no event yet")


func _test_pay_cost() -> void:
	var world := World.new(1)
	var side: Side = world.player_side()
	side.seed_stat(&"mana", 5.0)
	var card := Unit.new(side)
	WriteAuthority.mint(world, card)
	WriteAuthority.insert(side.get_container(&"hand"), card)

	var play: Array[Event] = MutationEngine.submit(
			PayCostRequest.new(&"pay", card, side, 3, 0, &"play_engaged", &""))
	check_eq(side.get_stat(&"mana"), 2.0, "mana pays on the target side")
	check(play.size() == 1 and play[0].name == &"play_engaged" and play[0].source == card,
			"the payment produces the engaged event, source the asked entity")
	check(play[0].components_of(NameEventData).is_empty(), "a play carries no ability name")

	var use: Array[Event] = MutationEngine.submit(
			PayCostRequest.new(&"pay", card, side, 1, 1, &"ability_used", &"heal"))
	check_eq(side.get_stat(&"mana"), 1.0, "the ability's mana pays the same road")
	check_eq(card.get_stat(&"tapped"), 1.0, "the tap is spent on the source")
	var names: Array[EventData] = use[0].components_of(NameEventData)
	check(use[0].name == &"ability_used" and names.size() == 1
			and (names[0] as NameEventData).role == &"ability"
			and (names[0] as NameEventData).name == &"heal",
			"ability_used carries the ability's name forward")


func _test_refusals() -> void:
	var world := World.new(1)
	var unit := _fielded_unit(world, world.player_side(), Vector3i(0, 0, 0), 2.0, 5.0, 1.0, 0.0)
	var no_target: Array[Event] = MutationEngine.submit(
			StatMutationRequest.new(&"stat_mutation", unit, null, &"attack", 1))
	check(no_target.is_empty() and unit.get_stat(&"attack") == 2.0,
			"a null target where the verb requires one is refused at submission")
	var stranger: Array[Event] = MutationEngine.submit(EngineRequest.new(&"?", unit, unit))
	check(stranger.is_empty(), "a request no procedure claims is refused at submission")
	var unhoused := Unit.new(world.player_side())
	WriteAuthority.mint(world, unhoused)
	var no_move: Array[Event] = MutationEngine.submit(MoveRequest.new(
			&"placement", null, world.board_manager.slot_at(Vector3i(0, 0, 0)),
			unhoused, &"slotted_unit"))
	check(no_move.is_empty() and unhoused.housing == null,
			"a move of unhoused cargo is refused")