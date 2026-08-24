extends TestCase

# Phase 1 of IMPLEMENTATION_PLAN.html — the world's skeleton. Pins computation only:
# entity construction and declarations (Core §1, §9), the container map and the
# membership primitives with their invariants (Core §2, Mutation §8), the stat write and
# its arithmetic, mint, the board's birth and fetch (Core §3), BoardGeometry (Core §3,
# A1 — the attack comparator pinned bit-identical to the pre-nuke ordering), the event
# structure (Core §8), and the world's seeded rng.


# A fixture bearer for the read-only refusal — nothing signed declares a read-only stat
# yet, so the mechanism is pinned against a test-owned type.
class ReadOnlyBearer extends GameEntity:
	func _declared_readonly_stats() -> Array[StringName]:
		var out: Array[StringName] = super._declared_readonly_stats()
		out.append(&"engraving")
		return out


func suite_name() -> String:
	return "core world (Phase 1)"


func run() -> void:
	_test_declarations()
	_test_membership_primitives()
	_test_stat_write()
	_test_world_birth()
	_test_board_fetch()
	_test_geometry_distance()
	_test_attack_preference()
	_test_aoe_shapes()
	_test_events()
	_test_seeded_rng()


func _test_declarations() -> void:
	var unit := Unit.new()
	check(unit.bears_stat(&"cost"), "a Unit bears Card's cost")
	for id: Array in [[&"attack"], [&"health"], [&"speed"], [&"shield"], [&"tapped"]]:
		check(unit.bears_stat(id[0]), "a Unit bears %s" % id[0])
	check_eq(unit.get_stat(&"attack"), 0.0, "stats seed to zero until authored")
	unit.seed_stat(&"attack", 3.0)
	check_eq(unit.get_stat(&"attack"), 3.0, "seed_stat commits at construction time")
	check(not unit.bears_stat(&"mana"), "a Unit does not bear a Side's stat")
	check(unit.get_container(&"contained") != null, "every entity bears `contained`")

	var side := Side.new()
	for cname: Array in [[&"deck"], [&"hand"], [&"graveyard"], [&"board"], [&"relics"], [&"contained"]]:
		check(side.get_container(cname[0]) != null, "a Side declares %s" % cname[0])
	check(side.bears_stat(&"mana") and side.bears_stat(&"mana_capacity"), "mana is a stat on the Side")
	check(side.allegiance == side, "a Side's allegiance is itself")

	var game := Game.new()
	check(game.get_container(&"sides") != null, "the Game declares sides")
	check(game.allegiance == null, "the Game belongs to no side")
	check(game.bears_stat(&"round"), "the Game bears round")

	var status := Status.new(&"poison")
	check(status.bears_stat(&"stacks"), "a Status bears stacks")
	check_eq(status.status_id, &"poison", "a Status carries its id")

	var slot := Slot.new(2, 1, side)
	check(slot.row == 2 and slot.col == 1, "a Slot's coordinate is set at construction")
	check(slot.get_container(&"slotted_unit") != null, "a Slot declares slotted_unit")
	check(slot.allegiance == side, "a Slot's allegiance is the side it was birthed for")

	check(Spell.new() is Card and Unit.new() is Card, "Unit and Spell are Card kinds")


func _test_membership_primitives() -> void:
	var side := Side.new()
	var hand: EntityContainer = side.get_container(&"hand")
	var deck: EntityContainer = side.get_container(&"deck")
	var card := Spell.new(side)

	check(card.housing == null, "a new entity is unhoused")
	WriteAuthority.insert(hand, card)
	check(card.housing == hand, "insert stamps the housing back-reference")
	check_eq(hand.members.size(), 1, "insert appends the member")
	check_eq(hand.name, &"hand", "the container's name duplicates its map key")
	check(hand.owner == side, "the container knows its owner")

	# One housing: a second insert without a remove is refused, committing nothing.
	WriteAuthority.insert(deck, card)
	check_eq(deck.members.size(), 0, "insert of a housed entity is refused")
	check(card.housing == hand, "the refused insert left the housing untouched")

	# A move is remove-from-housing then insert-at-destination.
	WriteAuthority.remove(hand, card)
	check(card.housing == null and hand.members.is_empty(), "remove clears housing and membership")
	WriteAuthority.insert(deck, card)
	check(card.housing == deck, "the entity is housed at the destination")

	# Remove of a non-member is refused.
	WriteAuthority.remove(hand, card)
	check(card.housing == deck, "remove from a container not housing the entity is refused")

	# Ordered insert.
	var second := Spell.new(side)
	WriteAuthority.insert(deck, second, 0)
	check(deck.members[0] == second and deck.members[1] == card, "insert at an index keeps order")


func _test_stat_write() -> void:
	var unit := Unit.new()
	var committed: float = WriteAuthority.stat_write(unit, &"health", 7.0)
	check_eq(committed, 7.0, "the stat write commits the value")
	check_eq(unit.get_stat(&"health"), 7.0, "the committed value is the borne value")

	# tapped floors at zero (Combat Frame §6) — arithmetic owned by the authority.
	check_eq(WriteAuthority.stat_write(unit, &"tapped", -2.0), 0.0, "tapped floors at zero")

	# Refusals commit nothing.
	WriteAuthority.stat_write(unit, &"mana", 5.0)
	check(not unit.bears_stat(&"mana"), "a write to an unborne stat is refused")
	var bearer := ReadOnlyBearer.new()
	WriteAuthority.stat_write(bearer, &"engraving", 4.0)
	check_eq(bearer.get_stat(&"engraving"), 0.0, "a write to a read-only stat is refused")


func _test_world_birth() -> void:
	var world := World.new(7)
	check(world.game != null and world.game.world == world, "the Game is minted into the world")
	var sides: Array[GameEntity] = world.game.get_container(&"sides").members
	check_eq(sides.size(), 2, "the Game houses two Sides")
	check(world.player_side() == sides[0] and world.enemy_side() == sides[1],
			"the sides container's order is the identity — player first")
	for side: GameEntity in sides:
		check(side.world == world, "each Side is minted into the world")
		check_eq(side.get_container(&"board").members.size(),
				BoardGeometry.ROWS * BoardGeometry.COLS, "each half's board holds its slots")
	var slot: Slot = world.board_manager.slot_at(Vector3i(0, 0, 0))
	check(slot != null and slot.world == world, "a birthed slot lives in the world")
	check(slot.housing == world.player_side().get_container(&"board"),
			"a slot is housed in its side's board container")
	check(slot.allegiance == world.player_side(), "a slot's allegiance is its housing side")


func _test_board_fetch() -> void:
	var world := World.new(7)
	var seen: Dictionary[Vector3i, bool] = {}
	for address: Vector3i in BoardGeometry.all_addresses():
		var slot: Slot = world.board_manager.slot_at(address)
		check(slot != null and slot.row == address.y and slot.col == address.z,
				"fetch answers %s with its stamped coordinate" % str(address))
		seen[address] = true
	check_eq(seen.size(), 24, "every address of the two halves is filed")
	check(world.board_manager.slot_at(Vector3i(0, 9, 9)) == null, "off-board fetch answers null")
	var listed: Array[Slot] = world.board_manager.slots_at(
			[Vector3i(0, 0, 0), Vector3i(0, 9, 9), Vector3i(1, 2, 3)] as Array[Vector3i])
	check_eq(listed.size(), 2, "slots_at yields the real addresses and skips the rest")


func _test_geometry_distance() -> void:
	for a: Vector3i in BoardGeometry.all_addresses():
		for b: Vector3i in BoardGeometry.all_addresses():
			if BoardGeometry.distance(a, b) != BoardGeometry.distance(b, a):
				check(false, "distance must be symmetric at %s/%s" % [str(a), str(b)])
				return
	check(true, "distance is symmetric over every pair")
	check_eq(BoardGeometry.distance(Vector3i(0, 0, 0), Vector3i(0, 0, 0)), 0, "distance to self is zero")
	check_eq(BoardGeometry.distance(Vector3i(0, 0, 3), Vector3i(1, 2, 0)), 1,
			"the front lines are adjacent across the battle line")
	check_eq(BoardGeometry.distance(Vector3i(0, 0, 0), Vector3i(0, 2, 3)), 5,
			"distance within a half is the walked cells")


# The pre-nuke attack_dist, written literally — THE oracle the comparator must reproduce
# bit-identically over its domain (attacker and target on opposite halves).
func _legacy_attack_dist(from: Vector3i, to: Vector3i) -> int:
	var lane_offset: int = absi(from.y + to.y - (BoardGeometry.ROWS - 1))
	var depth: int
	if from.x == 0:
		depth = BoardGeometry.COLS + to.z - from.z
	else:
		depth = BoardGeometry.COLS + from.z - to.z
	return depth * BoardGeometry.ROWS + lane_offset


func _test_attack_preference() -> void:
	var mismatches: int = 0
	for from: Vector3i in BoardGeometry.all_addresses():
		for to: Vector3i in BoardGeometry.all_addresses():
			if from.x == to.x:
				continue
			if BoardGeometry.attack_preference(from, to) != _legacy_attack_dist(from, to):
				mismatches += 1
	check_eq(mismatches, 0, "attack preference is bit-identical to the pre-nuke ordering")


func _test_aoe_shapes() -> void:
	var origin := Vector3i(0, 1, 2)
	check_eq(BoardGeometry.row_cells(origin).size(), BoardGeometry.COLS, "a row is its half's columns")
	check_eq(BoardGeometry.column_cells(origin).size(), BoardGeometry.ROWS, "a column is its half's rows")
	var ring: Array[Vector3i] = BoardGeometry.radius_cells(origin, 1)
	check_eq(ring.size(), 5, "radius 1 around an interior cell is the origin plus four neighbours")
	check(ring.has(origin), "radius includes the origin at distance zero")
	var crossing: Array[Vector3i] = BoardGeometry.radius_cells(Vector3i(0, 1, 3), 1)
	check(crossing.has(Vector3i(1, 1, 0)), "radius crosses the battle line to the facing cell")
	check_eq(BoardGeometry.square_cells(origin, 1).size(), 9, "square 1 around an interior cell is 3×3")
	var cone: Array[Vector3i] = BoardGeometry.cone_cells(Vector3i(0, 1, 2), 2)
	check(not cone.has(Vector3i(0, 1, 2)), "the origin is not in its own cone")
	check_eq(cone.size(), 3 + 3, "cone reach 2: three cells at step one, three at step two — the board's three lanes clamp the spread")
	for cell: Vector3i in BoardGeometry.cone_cells(Vector3i(1, 1, 0), 1):
		check(cell.x == 0, "an enemy front cell's cone of reach 1 lands wholly on the player half")


func _test_events() -> void:
	var unit := Unit.new()
	var event := Event.new(&"damaged", unit)
	check(event.source == unit and event.name == &"damaged", "the core: source and name")
	event.components.append(NameEventData.new(&"mutator_kind", &"poison"))
	event.components.append(StatMutationEventData.new(&"health", -2))
	var targets: Array[GameEntity] = [unit]
	event.components.append(EntityEventData.new(&"targets", targets))
	event.components.append(NameEventData.new(&"origin", &"hand"))
	var names: Array[EventData] = event.components_of(NameEventData)
	check_eq(names.size(), 2, "a reader receives all components of the named shape")
	check_eq((names[0] as NameEventData).role, &"mutator_kind", "components keep arrival order")
	var stats: Array[EventData] = event.components_of(StatMutationEventData)
	check((stats[0] as StatMutationEventData).delta == -2, "typed members read back")
	var entities: Array[EventData] = event.components_of(EntityEventData)
	check((entities[0] as EntityEventData).entities[0] == unit, "a singular target rides as a set of one")


func _test_seeded_rng() -> void:
	var a := World.new(1234)
	var b := World.new(1234)
	var same := true
	for i: int in 8:
		if a.rng.randf() != b.rng.randf():
			same = false
	check(same, "one seed, one sequence — the world's rng reproduces")
	var c := World.new(4321)
	check(a.rng.randf() != c.rng.randf() or a.rng.randf() != c.rng.randf(),
			"a different seed diverges")
