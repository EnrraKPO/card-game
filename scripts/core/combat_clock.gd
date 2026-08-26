class_name CombatClock
extends RefCounted

# The clock (Combat Frame §2): machinery embedded in the world, the frame's only moving
# part. It fires the frame's first-mover events and advances the round through its
# spans; every change of fact it causes is performed by effects reacting through the
# road. The clock decides two things alone: which event fires next, and when the fight
# has ended.
#
# One round, in order (§3): the opening — round_started fires and the Game's base rules
# run; the enemy's command span; the player's command span; the combat span — every
# fielded unit's moment, in activation order. The next round opens when the combat
# span's last moment has resolved; the fight's ending interrupts the round wherever it
# lands.
#
# The ending (§7): the clock ends the fight when a king's died event has fired and the
# delivery it belongs to has unfolded whole — every await below returns only when its
# holster has drained, so the check after each top-level firing is that condition. The
# enemy king's death is victory, the player king's defeat; when one act kills both
# kings, the fight is a defeat (§1). The ended fight fires no further first-mover
# events.

var _world_ref: WeakRef = null

var enemy_commander: Commander = null
var player_commander: Commander = null

# Empty while the fight runs; &"victory" or &"defeat" once ended (§1).
var outcome: StringName = &""


func _init(world: World) -> void:
	_world_ref = weakref(world)
	enemy_commander = Commander.new()
	player_commander = Commander.new()


func world() -> World:
	return _world_ref.get_ref()


# Runs rounds until the fight ends. `round_cap` is test tooling only — the game itself
# has no round limit (Frame §10); zero means none.
func run_fight(round_cap: int = 0) -> StringName:
	var played := 0
	while outcome == &"":
		await run_round()
		played += 1
		if round_cap > 0 and played >= round_cap:
			break
	return outcome


func run_round() -> void:
	var w: World = world()
	# The opening.
	await w.cascade.fire(Event.new(&"round_started", w.game, w.game))
	if _ended():
		return
	# The enemy commands first, then the player (A5).
	await enemy_commander.command(w)
	if _ended():
		return
	await player_commander.command(w)
	if _ended():
		return
	# The combat span: the activation order is computed ONCE at the span's open — the
	# single definition the turn-order display also walks. The ask fires at each unit
	# still fielded at its moment; a unit no longer fielded is passed over (§6).
	var order: Array[Unit] = CombatCascade.turn_order(w)
	for unit: Unit in order:
		if unit.housing == null or unit.housing.name != &"slotted_unit":
			continue
		await w.cascade.fire(Event.new(&"act", unit, w.game))
		if _ended():
			return


# The §7 check, run after each top-level delivery has unfolded whole. A king is fallen
# when a road to zero health has taken it there.
func _ended() -> bool:
	if outcome != &"":
		return true
	var w: World = world()
	var player_fallen := _king_fallen(w, w.player_side())
	var enemy_fallen := _king_fallen(w, w.enemy_side())
	if player_fallen:
		outcome = &"defeat"
	elif enemy_fallen:
		outcome = &"victory"
	return outcome != &""


static func _king_fallen(world: World, side: Side) -> bool:
	for entity: GameEntity in world.all_entities():
		if entity is Unit and (entity as Unit).is_king and entity.allegiance == side \
				and entity.get_stat(&"health") <= 0.0:
			return true
	return false
