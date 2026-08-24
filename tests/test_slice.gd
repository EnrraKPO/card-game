extends TestCase

# Phase 6 of IMPLEMENTATION_PLAN.html — the slice fight. The §4 content authored in the
# bible's markup (data/slice_fight.json), the fixed encounter assembled, the fight played
# whole: a scripted playthrough exercising the §5 coverage — strike pipeline, stat
# mutation with the health cap, poison's mint/stack/tick, the hourglass draw, the play
# and ability roads with pay, placement and burials with origin gating, hand-pick and
# its decline, stat-ranked and occasion's-targets elections, the unique pay mutator, the
# holster's depth-first chains, and the fight's ending. Deterministic under the fight's
# seed; the pinned numbers are this seed's fight. Visual acceptance is Enrra's.


# A picker answering from a scripted queue: each entry is a Callable(candidates) -> pick.
class QueuePicker extends TargetPicker:
	var queue: Array = []

	func pick(candidates: Array[GameEntity], _plate: Plate) -> GameEntity:
		@warning_ignore("redundant_await")
		await null
		if queue.is_empty():
			return null
		var chooser: Callable = queue.pop_front()
		return chooser.call(candidates)


# A commander playing a scripted list of steps per round; each step is an async
# Callable(world).
class ScriptedCommander extends Commander:
	var rounds: Array = []
	var at: int = 0

	func command(world: World) -> void:
		@warning_ignore("redundant_await")
		await null
		if at < rounds.size():
			for step: Callable in rounds[at]:
				await step.call(world)
		at += 1


var _world: World = null
var _picker: QueuePicker = null


func suite_name() -> String:
	return "the slice fight (Phase 6)"


func run() -> void:
	var fight: Dictionary = FightScreen.slice_fight()
	check(not fight.is_empty(), "the slice's fixed fight is authored")
	if fight.is_empty():
		return
	ContentLibrary.clear()
	for envelope: Variant in fight.content.cards:
		check(ContentLibrary.register_card(envelope), "card '%s' registers" % envelope.get("id"))
	for envelope: Variant in fight.content.statuses:
		check(ContentLibrary.register_status(envelope), "status '%s' registers" % envelope.get("id"))
	for envelope: Variant in fight.content.relics:
		check(ContentLibrary.register_relic(envelope), "relic '%s' registers" % envelope.get("id"))

	_world = World.new(int(fight.seed))
	_picker = QueuePicker.new()
	_world.picker = _picker
	check(Genesis.setup(_world, fight.player, fight.enemy), "genesis assembles the encounter")
	await _playthrough()


func _hand(id: StringName) -> Card:
	for member: GameEntity in _world.player_side().get_container(&"hand").members:
		if member.id == id:
			return member as Card
	return null


func _standing(id: StringName, side: Side) -> Unit:
	for entity: GameEntity in _world.all_entities():
		if entity is Unit and entity.id == id and entity.allegiance == side \
				and entity.housing != null and entity.housing.name == &"slotted_unit":
			return entity as Unit
	return null


func _slot(address: Vector3i) -> Callable:
	return func(_candidates: Array[GameEntity]) -> GameEntity:
		return _world.board_manager.slot_at(address)


func _by_id(id: StringName) -> Callable:
	return func(candidates: Array[GameEntity]) -> GameEntity:
		for candidate: GameEntity in candidates:
			if candidate.id == id:
				return candidate
		return null


func _decline() -> Callable:
	return func(_candidates: Array[GameEntity]) -> GameEntity:
		return null


func _play(id: StringName, picks: Array) -> Callable:
	return func(world: World) -> void:
		var card: Card = _hand(id)
		if card == null:
			check(false, "expected '%s' in hand to play" % id)
			return
		_picker.queue.append_array(picks)
		await world.cascade.fire(Event.new(&"play", card))


func _use(unit_id: StringName, ability: StringName, picks: Array) -> Callable:
	return func(world: World) -> void:
		var unit: Unit = _standing(unit_id, world.player_side())
		if unit == null:
			check(false, "expected '%s' fielded to use %s" % [unit_id, ability])
			return
		_picker.queue.append_array(picks)
		var ask := Event.new(&"use_ability", unit)
		ask.components.append(NameEventData.new(&"ability", ability))
		await world.cascade.fire(ask)


func _playthrough() -> void:
	var player: Side = _world.player_side()
	var enemy: Side = _world.enemy_side()
	var scripted := ScriptedCommander.new()
	_world.clock.player_commander = scripted
	_world.clock.enemy_commander = EnemyCommander.new()

	# The deck is shuffled by the seed; the script plays the draws this seed provides
	# (opening hand cleric/fireball/avenger, deck squire, squire, sentinel, venom_adder),
	# refusing loudly if the order ever differs.
	scripted.rounds = [
		[_r1_squire],
		[_r2_declined_cleric, _r2_second_squire, _r2_avenger],
		[_r3_adder, _r3_cleric],
		[_r4_heal_king, _r4_sentinel],
		[_r5_move_cleric, _r5_fireball],
	]

	var outcome: StringName = await _world.clock.run_fight(40)
	check_eq(outcome, &"victory", "the fight plays whole to the captain's fall")
	check(_standing(&"captain", enemy) == null, "the fallen captain no longer stands")
	check_eq(enemy.get_container(&"graveyard").members.filter(
			func(e: GameEntity) -> bool: return e.id == &"captain").size(), 1,
			"the captain's death buried it — the built-in road")
	var avenger: Unit = null
	for entity: GameEntity in _world.all_entities():
		if entity.id == &"avenger" and entity.allegiance == player:
			avenger = entity as Unit
	if avenger != null and not player.get_container(&"graveyard").members.is_empty():
		check(avenger.get_stat(&"attack") > 2.0,
				"allied deaths reached the Avenger through the holster's chain")
	check(_world.game.get_stat(&"round") >= 5.0, "the rounds turned")

# ── The scripted rounds ────────────────────────────────────────────────────────────────

func _r1_squire(world: World) -> void:
	var player: Side = world.player_side()
	var before: int = player.get_container(&"hand").members.size()
	await _play(&"squire", [_slot(Vector3i(0, 1, 1))]).call(world)
	check_eq(player.get_container(&"hand").members.size(), before,
			"the played card left the hand and the Hourglass drew one back")
	check(_standing(&"squire", player) != null, "the squire stands fielded")


func _r2_declined_cleric(world: World) -> void:
	var player: Side = world.player_side()
	var mana: float = player.get_stat(&"mana")
	await _play(&"cleric", [_decline()]).call(world)
	check_eq(player.get_stat(&"mana"), mana, "a declined pick ends the play unpaid")
	check(_hand(&"cleric") != null, "the declined card stays in hand")


func _r2_second_squire(world: World) -> void:
	await _play(&"squire", [_slot(Vector3i(0, 0, 1))]).call(world)
	check(_hand(&"venom_adder") != null,
			"the Hourglass drew the deck's last card for the arrival")


func _r3_adder(world: World) -> void:
	await _play(&"venom_adder", [_slot(Vector3i(0, 2, 1)), _by_id(&"captain")]).call(world)
	var captain: Unit = _standing(&"captain", world.enemy_side())
	var poisons: Array[GameEntity] = captain.get_container(&"contained").members.filter(
			func(e: GameEntity) -> bool: return e is Status and (e as Status).status_id == &"poison")
	check_eq(poisons.size(), 1, "the play's substantive effect minted Poison onto the picked captain")
	if not poisons.is_empty():
		check_eq(poisons[0].get_stat(&"stacks"), 2.0, "with the authored stacks")


func _r5_fireball(world: World) -> void:
	var captain: Unit = _standing(&"captain", world.enemy_side())
	var before: float = captain.get_stat(&"health") + captain.get_stat(&"shield")
	await _play(&"fireball", [_by_id(&"captain")]).call(world)
	var after: float = captain.get_stat(&"health") + captain.get_stat(&"shield")
	check_eq(before - after, 4.0, "the fireball's damage landed whole")
	var burned: Array[GameEntity] = world.player_side().get_container(&"graveyard").members.filter(
			func(e: GameEntity) -> bool: return e.id == &"fireball")
	check_eq(burned.size(), 1, "a spell is spent by its play — buried from the hand")


func _r3_cleric(world: World) -> void:
	await _play(&"cleric", [_slot(Vector3i(0, 0, 0))]).call(world)
	check(_standing(&"cleric", world.player_side()) != null, "the cleric stands fielded")


func _r4_sentinel(world: World) -> void:
	await _play(&"sentinel", [_slot(Vector3i(0, 1, 2))]).call(world)
	var sentinel: Unit = _standing(&"sentinel", world.player_side())
	check(sentinel != null and sentinel.is_building and not sentinel.abilities.has(&"move"),
			"the sentinel stands rooted — a building, no Move appointment")


func _r4_heal_king(world: World) -> void:
	var king: Unit = _standing(&"king", world.player_side())
	var before: float = king.get_stat(&"health")
	await _use(&"cleric", &"heal", [_by_id(&"king")]).call(world)
	check_eq(king.get_stat(&"health"), minf(before + 3.0, king.get_stat(&"max_health")),
			"the heal lands capped at max health — the WriteAuthority's arithmetic")


func _r5_move_cleric(world: World) -> void:
	var cleric: Unit = _standing(&"cleric", world.player_side())
	if cleric == null:
		check(false, "expected the cleric alive to move")
		return
	await _use(&"cleric", &"move", [_slot(Vector3i(0, 0, 3))]).call(world)
	check(cleric.housing == world.board_manager.slot_at(Vector3i(0, 0, 3))
			.get_container(&"slotted_unit"), "Move carried the cleric forward, free")


func _r2_avenger(world: World) -> void:
	await _play(&"avenger", [_slot(Vector3i(0, 2, 0))]).call(world)
	check(_standing(&"avenger", world.player_side()) != null, "the avenger stands fielded")
