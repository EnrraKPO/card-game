extends TestCase

# Phase 4 of IMPLEMENTATION_PLAN.html — the card roads. Pins the play effect with pay
# (Core §5), the substantive effects on play_engaged, the built-in placement and burials
# and the fielded event (Core §6, §2), the ability expansion (Core §7) with Move
# (A3, A9), and the main action (Combat Frame §6, A6). Exit: a card plays from hand to
# board, an ability activates, a death buries — all through the road.


class TestPicker extends TargetPicker:
	var answer: GameEntity = null

	func pick(_candidates: Array[GameEntity], _plate: Plate) -> GameEntity:
		@warning_ignore("redundant_await")
		await null
		return answer


func suite_name() -> String:
	return "card roads (Phase 4)"


func run() -> void:
	await _test_unit_play()
	await _test_declined_and_unaffordable()
	await _test_spell_play()
	await _test_ability_road()
	await _test_move()
	await _test_main_action()
	await _test_death_buries()


func _hand_unit(world: World, side: Side, cost: float) -> Unit:
	var unit := Unit.new(side)
	unit.seed_stat(&"cost", cost)
	unit.seed_stat(&"attack", 2.0)
	unit.seed_stat(&"health", 5.0)
	unit.seed_stat(&"speed", 1.0)
	WriteAuthority.mint(world, unit)
	WriteAuthority.insert(side.get_container(&"hand"), unit)
	return unit


func _fielded_unit(world: World, side: Side, address: Vector3i) -> Unit:
	var unit := _hand_unit(world, side, 0.0)
	WriteAuthority.remove(side.get_container(&"hand"), unit)
	var slot: Slot = world.board_manager.slot_at(address)
	WriteAuthority.insert(slot.get_container(&"slotted_unit"), unit)
	return unit


func _test_unit_play() -> void:
	var world := World.new(1)
	var side: Side = world.player_side()
	side.seed_stat(&"mana", 4.0)
	var unit := _hand_unit(world, side, 3.0)
	var slot: Slot = world.board_manager.slot_at(Vector3i(0, 1, 2))
	var picker := TestPicker.new()
	picker.answer = slot
	world.picker = picker

	check(unit.payable(), "the payability query answers for an affordable hand card")
	await world.cascade.fire(Event.new(&"play", unit))
	check_eq(side.get_stat(&"mana"), 1.0, "the play's cost is paid from the holder's side")
	check(unit.housing == slot.get_container(&"slotted_unit"),
			"the placement effect fields the unit on the picked slot")
	check(not unit.payable(), "a fielded card is no longer payable")


func _test_declined_and_unaffordable() -> void:
	var world := World.new(1)
	var side: Side = world.player_side()
	side.seed_stat(&"mana", 4.0)
	var unit := _hand_unit(world, side, 3.0)

	# The default picker declines: the empty election refuses the ask before payment.
	await world.cascade.fire(Event.new(&"play", unit))
	check_eq(side.get_stat(&"mana"), 4.0, "a declined pick ends the play unpaid")
	check(unit.housing.name == &"hand", "the card stays in hand")

	var dear := _hand_unit(world, side, 9.0)
	var picker := TestPicker.new()
	picker.answer = world.board_manager.slot_at(Vector3i(0, 0, 0))
	world.picker = picker
	check(not dear.payable(), "payability sees past the open mana")
	await world.cascade.fire(Event.new(&"play", dear))
	check(side.get_stat(&"mana") == 4.0 and dear.housing.name == &"hand",
			"an unaffordable play does not engage")


func _test_spell_play() -> void:
	var world := World.new(1)
	var side: Side = world.player_side()
	side.seed_stat(&"mana", 2.0)
	var foe := _fielded_unit(world, world.enemy_side(), Vector3i(1, 0, 0))
	var spell := Spell.new(side)
	spell.seed_stat(&"cost", 2.0)
	WriteAuthority.mint(world, spell)
	WriteAuthority.insert(side.get_container(&"hand"), spell)
	# The Fireball shape: a substantive effect on play_engaged, hand-picked enemy unit,
	# damage payload — authored in the bible's markup.
	var substantive: Effect = MarkupParse.parse_effect({
		"trigger": {"event": "play_engaged", "entity_conditions": {"entries": [
			{"route": "source", "conditions": [{"kind": "is_holder"}]},
		]}},
		"targeting": {"decision": "hand_pick",
				"conditions": [{"kind": "is_enemy"}, {"kind": "is_unit"}]},
		"payload": [{"damage": {"amount": 4}}],
	})
	spell.effects.append(substantive)
	var picker := TestPicker.new()
	picker.answer = foe
	world.picker = picker

	await world.cascade.fire(Event.new(&"play", spell))
	check_eq(side.get_stat(&"mana"), 0.0, "the spell's play is paid")
	check(spell.housing == side.get_container(&"graveyard"),
			"a spell is spent by its play — the burial lands it in the graveyard")
	check_eq(foe.get_stat(&"health"), 1.0, "the substantive effect's damage reached the pick")


func _test_ability_road() -> void:
	var world := World.new(1)
	var side: Side = world.player_side()
	side.seed_stat(&"mana", 3.0)
	var cleric := _fielded_unit(world, side, Vector3i(0, 0, 0))
	var wounded := _fielded_unit(world, side, Vector3i(0, 1, 0))
	WriteAuthority.stat_write(wounded, &"health", 2.0, [] as Array[Event])
	var rival := _fielded_unit(world, side, Vector3i(0, 2, 0))
	# The Heal shape (Core §7's markup form): cost, hand-picked ally unit, positive
	# health stat mutation.
	var appointed: bool = Ability.appoint(cleric, {
		"name": "heal",
		"cost": {"mana": 2},
		"targeting": {"decision": "hand_pick",
				"conditions": [{"kind": "is_ally"}, {"kind": "is_unit"}]},
		"effect": {"payload": [{"stat_mutation": {"stat": "health", "delta": 3}}]},
	})
	check(appointed, "the ability markup form parses and expands")
	check(cleric.abilities.has(&"heal"), "the holder bears the ask capability")
	Ability.appoint(rival, {
		"name": "heal", "cost": {"mana": 2},
		"targeting": {"decision": "hand_pick",
				"conditions": [{"kind": "is_ally"}, {"kind": "is_unit"}]},
		"effect": {"payload": [{"stat_mutation": {"stat": "health", "delta": 3}}]},
	})
	var picker := TestPicker.new()
	picker.answer = wounded
	world.picker = picker

	var ask := Event.new(&"use_ability", cleric)
	ask.components.append(NameEventData.new(&"ability", &"heal"))
	await world.cascade.fire(ask)
	check_eq(side.get_stat(&"mana"), 1.0, "the ability's cost is paid — once, by the asked holder")
	check_eq(wounded.get_stat(&"health"), 5.0, "the substantive effect healed the pick")
	check_eq(rival.get_stat(&"tapped"), 0.0, "the rival bearer of the same name stayed out of it")

	# Affordability gates the second use.
	await world.cascade.fire(ask)
	check_eq(side.get_stat(&"mana"), 1.0, "an unaffordable use does not engage")


func _test_move() -> void:
	var world := World.new(1)
	var side: Side = world.player_side()
	var walker := _fielded_unit(world, side, Vector3i(0, 0, 0))
	var tower := Unit.new(side, true)
	tower.seed_stat(&"health", 5.0)
	WriteAuthority.mint(world, tower)
	WriteAuthority.insert(world.board_manager.slot_at(Vector3i(0, 2, 0))
			.get_container(&"slotted_unit"), tower)
	check(walker.abilities.has(&"move"), "machinery appoints Move on every unit")
	check(not tower.abilities.has(&"move"), "a building does not receive it — rooted")

	var destination: Slot = world.board_manager.slot_at(Vector3i(0, 1, 3))
	var picker := TestPicker.new()
	picker.answer = destination
	world.picker = picker
	var ask := Event.new(&"use_ability", walker)
	ask.components.append(NameEventData.new(&"ability", &"move"))
	await world.cascade.fire(ask)
	check(walker.housing == destination.get_container(&"slotted_unit"),
			"Move carries the unit to the picked slot — free, through the placement mutator")


func _test_main_action() -> void:
	var world := World.new(7)
	world.game.seed_stat(&"crit_base", 0.0)
	var striker := _fielded_unit(world, world.player_side(), Vector3i(0, 1, 3))
	var front := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 0))
	var back := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 3))
	WriteAuthority.stat_write(front, &"health", 9.0, [] as Array[Event])
	WriteAuthority.stat_write(back, &"health", 9.0, [] as Array[Event])
	check_eq(striker.main_action_targets(), [front] as Array[GameEntity],
			"the target poll answers the attack preference — nearer column wins")

	await world.cascade.fire(Event.new(&"act", striker))
	check_eq(front.get_stat(&"health"), 7.0, "the main action strikes the elected enemy")
	check_eq(striker.get_stat(&"tapped"), 1.0, "acting spends the tap")
	await world.cascade.fire(Event.new(&"act", striker))
	check_eq(front.get_stat(&"health"), 7.0, "a tapped unit's main action does not engage")


func _test_death_buries() -> void:
	var world := World.new(7)
	world.game.seed_stat(&"crit_base", 0.0)
	var striker := _fielded_unit(world, world.player_side(), Vector3i(0, 1, 3))
	WriteAuthority.stat_write(striker, &"attack", 9.0, [] as Array[Event])
	var victim := _fielded_unit(world, world.enemy_side(), Vector3i(1, 1, 0))
	var slot: Slot = world.board_manager.slot_at(Vector3i(1, 1, 0))

	await world.cascade.fire(Event.new(&"act", striker))
	check(victim.get_stat(&"health") <= 0.0, "the lethal strike lands")
	check(victim.housing == world.enemy_side().get_container(&"graveyard"),
			"the death buries — the built-in effect walked the holder to its graveyard")
	check(slot.get_container(&"slotted_unit").members.is_empty(), "the slot stands vacant")