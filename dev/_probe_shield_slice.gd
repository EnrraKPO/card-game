extends Node

# Dev probe: the slice fight under the shield recovery rule (A13) — test_slice's
# scripted rounds replayed without its checks, then auto-combat, watching both
# boards round by round.


class QueuePicker extends TargetPicker:
	var queue: Array = []

	func pick(candidates: Array[GameEntity], _plate: Plate) -> GameEntity:
		@warning_ignore("redundant_await")
		await null
		if queue.is_empty():
			return null
		var chooser: Callable = queue.pop_front()
		return chooser.call(candidates)


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


func _ready() -> void:
	var fight: Dictionary = FightScreen.slice_fight()
	ContentLibrary.clear()
	for envelope: Variant in fight.content.cards:
		ContentLibrary.register_card(envelope)
	for envelope: Variant in fight.content.statuses:
		ContentLibrary.register_status(envelope)
	for envelope: Variant in fight.content.relics:
		ContentLibrary.register_relic(envelope)
	_world = World.new(int(fight.seed))
	_picker = QueuePicker.new()
	_world.picker = _picker
	Genesis.setup(_world, fight.player, fight.enemy)
	_world.clock.enemy_commander = EnemyCommander.new()
	var scripted := ScriptedCommander.new()
	scripted.rounds = [
		[_play(&"squire", [_slot(Vector3i(0, 1, 1))])],
		[_play(&"cleric", [_decline()]), _play(&"squire", [_slot(Vector3i(0, 0, 1))]),
				_play(&"avenger", [_slot(Vector3i(0, 2, 0))])],
		[_play(&"venom_adder", [_slot(Vector3i(0, 2, 1)), _by_id(&"captain")]),
				_play(&"cleric", [_slot(Vector3i(0, 0, 0))])],
		[_use(&"cleric", &"heal", [_by_id(&"king")]),
				_play(&"sentinel", [_slot(Vector3i(0, 1, 2))])],
		[_use(&"cleric", &"move", [_slot(Vector3i(0, 0, 3))]),
				_play(&"fireball", [_by_id(&"captain")])],
	]
	_world.clock.player_commander = scripted
	for i: int in 40:
		await _world.clock.run_round()
		var line := "round %d:" % roundi(_world.game.get_stat(&"round"))
		for entity: GameEntity in _world.all_entities():
			if entity is Unit and entity.housing != null \
					and entity.housing.name == &"slotted_unit":
				var side := "P" if entity.allegiance == _world.player_side() else "E"
				line += " %s:%s h%d s%d" % [side, entity.id,
						roundi(entity.get_stat(&"health")), roundi(entity.get_stat(&"shield"))]
		print(line)
		if _world.clock.outcome != &"":
			print("outcome: ", _world.clock.outcome)
			break
	get_tree().quit()


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
			print("  MISSING in hand: ", id)
			return
		_picker.queue.append_array(picks)
		await world.cascade.fire(Event.new(&"play", card))


func _use(unit_id: StringName, ability: StringName, picks: Array) -> Callable:
	return func(world: World) -> void:
		var unit: Unit = _standing(unit_id, world.player_side())
		if unit == null:
			print("  MISSING fielded: ", unit_id)
			return
		_picker.queue.append_array(picks)
		var ask := Event.new(&"use_ability", unit)
		ask.components.append(NameEventData.new(&"ability", ability))
		await world.cascade.fire(ask)
