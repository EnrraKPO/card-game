extends TestCase

# Phase 5a of IMPLEMENTATION_PLAN.html — the combat frame (Combat Frame Design, signed).
# Pins the clock's round — opening, command spans, combat span in activation order with
# pass-over — the six base rules in declared order, genesis as construction, the
# fight's ending on a king's death, the A7 envelope through the ContentLibrary, and the
# world's copy.


func suite_name() -> String:
	return "combat frame (Phase 5a)"


func run() -> void:
	_register_content()
	_test_envelope()
	await _test_round_flow()
	await _test_shield_recovery()
	await _test_fight_ends()
	await _test_pass_over()
	_test_copy()


func _register_content() -> void:
	ContentLibrary.clear()
	check(ContentLibrary.register_card({"id": "squire", "name": "Squire", "kind": "unit",
			"stats": {"cost": 1, "attack": 2, "health": 5, "speed": 1}}), "a plain unit registers")
	check(ContentLibrary.register_card({"id": "king", "name": "King", "kind": "unit",
			"king": true, "stats": {"cost": 0, "attack": 1, "health": 20, "speed": 3}}),
			"the king's envelope registers with its birth fact")
	check(ContentLibrary.register_card({"id": "tower", "name": "Tower", "kind": "unit",
			"building": true, "stats": {"cost": 2, "attack": 0, "health": 8, "speed": 0}}),
			"a building registers")
	check(ContentLibrary.register_card({"id": "guard", "name": "Guard", "kind": "unit",
			"stats": {"cost": 1, "attack": 1, "health": 4, "speed": 1, "shield": 3}}),
			"a shielded unit registers")


func _test_envelope() -> void:
	check(not ContentLibrary.register_card({"id": "odd", "kind": "unit", "power": 3}),
			"a stranger envelope key is refused")
	check(not ContentLibrary.register_card({"id": "odd", "kind": "beast"}),
			"an unknown kind is refused")
	check(ContentLibrary.build_card(&"nobody", null) == null, "an unregistered id builds nothing")

	var world := World.new(3)
	var king: Card = ContentLibrary.build_card(&"king", world.player_side())
	check(king is Unit and (king as Unit).is_king, "the king fact decides on the built unit")
	check_eq(king.get_stat(&"health"), 20.0, "the stats map seeds construction")
	check_eq(king.display_name, "King", "identity dresses the card")
	var tower: Card = ContentLibrary.build_card(&"tower", world.player_side())
	check((tower as Unit).is_building and not tower.abilities.has(&"move"),
			"a building is rooted — no Move appointment")
	var twin_squire_a: Card = ContentLibrary.build_card(&"squire", world.player_side())
	var twin_squire_b: Card = ContentLibrary.build_card(&"squire", world.player_side())
	check(twin_squire_a.play_effect == twin_squire_b.play_effect,
			"card copies share the one machinery instance")


func _fight_world(seed_value: int) -> World:
	var world := World.new(seed_value)
	# Determinism for pinned numbers: no dodge, no crit.
	world.game.seed_stat(&"dodge_speed_rating", 0.0)
	world.game.seed_stat(&"dodge_difference_rating", 0.0)
	world.game.seed_stat(&"crit_base", 0.0)
	world.game.seed_stat(&"crit_speed_rating", 0.0)
	var config: Dictionary = {
		"deck": ["squire", "squire", "squire", "squire", "squire"],
		"units": [{"id": "king", "slot": [1, 0]}],
	}
	check(Genesis.setup(world, config, config.duplicate(true)), "genesis builds the fight whole")
	return world


func _test_round_flow() -> void:
	var world := _fight_world(21)
	var side: Side = world.player_side()
	check_eq(side.get_stat(&"mana"), 1.0, "mana seeds to the starting capacity")
	check_eq(side.get_container(&"hand").members.size(), 3, "the opening hand is the seeded size")
	check_eq(side.get_container(&"deck").members.size(), 2, "the deck holds the rest")

	await world.clock.run_round()
	check_eq(world.game.get_stat(&"round"), 1.0, "the round count rule raised the round")
	check_eq(side.get_stat(&"mana_capacity"), 2.0, "the ramp rule raised the capacity")
	check_eq(side.get_stat(&"mana"), 2.0, "the refill rule raised mana to it")
	check_eq(side.get_container(&"hand").members.size(), 4, "the draw rule drew the turn draw")

	# The combat span ran: the kings struck each other (attack 1, mirrored front slots).
	var player_king := world.board_manager.slot_at(Vector3i(0, 1, 0)) \
			.get_container(&"slotted_unit").members[0] as Unit
	var enemy_king := world.board_manager.slot_at(Vector3i(1, 1, 0)) \
			.get_container(&"slotted_unit").members[0] as Unit
	check(player_king.get_stat(&"health") == 19.0 and enemy_king.get_stat(&"health") == 19.0,
			"each king's moment struck the other across the line")
	check(player_king.get_stat(&"tapped") == 1.0, "acting spent the tap")

	await world.clock.run_round()
	check_eq(world.game.get_stat(&"round"), 2.0, "the next round opens after the span's last moment")
	check_eq(player_king.get_stat(&"health"), 18.0, "the untap rule freed the second round's acts")


# The shield recovery rule (Combat Frame §4, A13): the opening raises a fielded unit's
# shield to its authored value — a raise, never a drain.
func _test_shield_recovery() -> void:
	var world := World.new(24)
	var player_config: Dictionary = {
		"deck": ["squire", "squire", "squire", "squire"],
		"units": [{"id": "king", "slot": [1, 0]}, {"id": "guard", "slot": [0, 0]}],
	}
	var enemy_config: Dictionary = {
		"deck": ["squire", "squire", "squire", "squire"],
		"units": [{"id": "king", "slot": [1, 0]}],
	}
	check(Genesis.setup(world, player_config, enemy_config), "genesis fields the shielded guard")
	var guard := world.board_manager.slot_at(Vector3i(0, 0, 0)) \
			.get_container(&"slotted_unit").members[0] as Unit
	check_eq(guard.get_stat(&"shield"), 3.0, "the envelope seeds the authored shield")

	MutationEngine.submit(DamageRequest.new(&"test", null, guard, 2))
	check_eq(guard.get_stat(&"shield"), 1.0, "damage spends the shield first")

	await world.cascade.fire(Event.new(&"round_started", world.game))
	check_eq(guard.get_stat(&"shield"), 3.0,
			"the shield recovery rule raises the shield to its authored value")

	MutationEngine.submit(StatMutationRequest.new(&"test", null, guard, &"shield", 4))
	await world.cascade.fire(Event.new(&"round_started", world.game))
	check_eq(guard.get_stat(&"shield"), 7.0,
			"shield standing above the authored value stays — a raise, never a drain")


func _test_fight_ends() -> void:
	var world := _fight_world(22)
	var player_king := world.board_manager.slot_at(Vector3i(0, 1, 0)) \
			.get_container(&"slotted_unit").members[0] as Unit
	WriteAuthority.stat_write(player_king, &"attack", 30.0, [] as Array[Event])
	var outcome: StringName = await world.clock.run_fight(5)
	check_eq(outcome, &"victory", "the enemy king's death ends the fight in victory")
	var enemy_king_grave: EntityContainer = world.enemy_side().get_container(&"graveyard")
	check_eq(enemy_king_grave.members.size(), 1, "the fallen king was buried before the end")

	var doomed := _fight_world(23)
	var enemy_king := doomed.board_manager.slot_at(Vector3i(1, 1, 0)) \
			.get_container(&"slotted_unit").members[0] as Unit
	WriteAuthority.stat_write(enemy_king, &"attack", 30.0, [] as Array[Event])
	check_eq(await doomed.clock.run_fight(5), &"defeat",
			"the player king's death ends the fight in defeat")


func _test_pass_over() -> void:
	var world := _fight_world(24)
	# A fast player reaper kills the enemy king's escort before its moment.
	var reaper: Card = ContentLibrary.build_card(&"squire", world.player_side())
	WriteAuthority.stat_write(reaper, &"attack", 9.0, [] as Array[Event])
	WriteAuthority.stat_write(reaper, &"speed", 9.0, [] as Array[Event])
	WriteAuthority.mint(world, reaper)
	WriteAuthority.insert(world.board_manager.slot_at(Vector3i(0, 0, 3))
			.get_container(&"slotted_unit"), reaper)
	var escort: Card = ContentLibrary.build_card(&"squire", world.enemy_side())
	WriteAuthority.mint(world, escort)
	WriteAuthority.insert(world.board_manager.slot_at(Vector3i(1, 2, 0))
			.get_container(&"slotted_unit"), escort)
	# The escort shares the reaper's lane on the front column; the enemy king sits one
	# lane off — the preference elects the escort.
	await world.clock.run_round()
	check(escort.get_stat(&"health") <= 0.0, "the reaper's moment killed the escort")
	check_eq(escort.get_stat(&"tapped"), 0.0,
			"a unit no longer fielded at its moment is passed over — it never acted")


func _test_copy() -> void:
	var world := _fight_world(25)
	var player_king := world.board_manager.slot_at(Vector3i(0, 1, 0)) \
			.get_container(&"slotted_unit").members[0] as Unit
	MutationEngine.submit(StatusRequest.new(&"status", null, player_king, &"poison", 2))
	var twin: World = world.copy()
	var twin_king := twin.board_manager.slot_at(Vector3i(0, 1, 0)) \
			.get_container(&"slotted_unit").members[0] as Unit
	check(twin_king != player_king, "the twin is its own entity")
	check(twin_king.allegiance == twin.player_side(), "allegiance remaps to the twin's side")
	check_eq(twin_king.get_stat(&"health"), 20.0, "the facts copy by value")
	check(twin_king.main_action == player_king.main_action,
			"the stateless machinery is shared, not cloned")
	var twin_status := twin_king.get_container(&"contained").members[0] as Status
	check(twin_status.status_id == &"poison" and twin_status.get_stat(&"stacks") == 2.0,
			"the carried status cloned with its stacks")
	check_eq(twin.player_side().get_container(&"hand").members.size(), 3,
			"the zones cloned member for member")

	MutationEngine.submit(DamageRequest.new(&"test", null, twin_king, 6))
	check(twin_king.get_stat(&"health") == 14.0 and player_king.get_stat(&"health") == 20.0,
			"a wound in the twin never reaches the live world")