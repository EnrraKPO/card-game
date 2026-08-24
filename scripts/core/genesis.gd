class_name Genesis
extends RefCounted

# Genesis is construction, not mutation (Mutation §13; Combat Frame §8): setup builds
# every entity in its starting container directly, before the first event fires. Both
# sides' decks shuffled by the world's seeded rng, each opening hand of the seeded size
# built directly into its hand container, each side's mana_capacity and mana seeded to
# the starting capacity, kings and any authored starting units housed on their slots.
# The first round_started is the first event ever fired — the clock's, after this
# returns.
#
# A side's setup (B33): {"deck": [card ids], "units": [{"id": ..., "slot": [row, col]}],
# "relics": [ids]} — the king enters through "units" as a card whose envelope bears the
# king fact.


static func setup(world: World, player: Dictionary, enemy: Dictionary) -> bool:
	if not _setup_side(world, world.player_side(), 0, player):
		return false
	if not _setup_side(world, world.enemy_side(), 1, enemy):
		return false
	return true


static func _setup_side(world: World, side: Side, half: int, config: Dictionary) -> bool:
	for key: String in config:
		if not ["deck", "units", "relics"].has(key):
			push_error("Genesis: setup key '%s' is a stranger — refused" % key)
			return false
	var starting: float = world.game.get_stat(&"starting_mana_capacity")
	side.seed_stat(&"mana_capacity", starting)
	side.seed_stat(&"mana", starting)

	var deck: EntityContainer = side.get_container(&"deck")
	for card_id: Variant in config.get("deck", []):
		var card: Card = ContentLibrary.build_card(StringName(card_id as String), side)
		if card == null:
			return false
		WriteAuthority.mint(world, card)
		WriteAuthority.insert(deck, card)
	_shuffle(deck.members, world.rng)

	for placement: Variant in config.get("units", []):
		var unit: Card = ContentLibrary.build_card(
				StringName((placement as Dictionary).id as String), side)
		if unit == null:
			return false
		var at: Array = (placement as Dictionary).slot
		var slot: Slot = world.board_manager.slot_at(Vector3i(half, int(at[0]), int(at[1])))
		if slot == null:
			push_error("Genesis: no slot at %s — refused" % str(at))
			return false
		WriteAuthority.mint(world, unit)
		WriteAuthority.insert(slot.get_container(&"slotted_unit"), unit)

	for relic_id: Variant in config.get("relics", []):
		var relic: Relic = ContentLibrary.build_relic(StringName(relic_id as String), side)
		if relic == null:
			return false
		WriteAuthority.mint(world, relic)
		WriteAuthority.insert(side.get_container(&"relics"), relic)

	# The opening hand, built directly from the shuffled deck's top.
	var hand: EntityContainer = side.get_container(&"hand")
	for i: int in roundi(world.game.get_stat(&"opening_hand_size")):
		if deck.members.is_empty():
			break
		var top: GameEntity = deck.members[0]
		WriteAuthority.remove(deck, top)
		WriteAuthority.insert(hand, top)
	return true


# Fisher-Yates on the world's seeded rng — members reorder in place; housing is
# untouched by order.
static func _shuffle(members: Array[GameEntity], rng: RandomNumberGenerator) -> void:
	for i: int in range(members.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var held: GameEntity = members[i]
		members[i] = members[j]
		members[j] = held
