class_name CombatCascade
extends RefCounted

# The cascade (Mutation System Design §9, §12): an event fires, the cascade gathers
# every eligible effect into the roster, orders it, and runs it — reactions resolve in
# roster order, one effect at a time, each through the EffectConductor. Eligibility is
# existence: a holder is polled while it exists in the world; the gather inspects no
# other fact of it — any finer gating is a condition.
#
# One holster per payload delivery, owned here: the cascade opens the delivery and
# creates the holster; after the conductor returns, the cascade fires the holster's
# events. The holster is a queue — events fire in arrival order — and firing is
# depth-first: an event may trigger a fresh effect, which resolves in full — its own
# payload, its own holster — before the next event of the outer holster fires. A death
# event is an ordinary holstered event; burial is the holder's built-in effect reacting
# to its own died.

var _world_ref: WeakRef = null
var _conductor: EffectConductor = null


func _init(world: World) -> void:
	_world_ref = weakref(world)
	_conductor = EffectConductor.new(world)


func fire(event: Event) -> void:
	var world: World = _world_ref.get_ref()
	var roster: Array[Dictionary] = _gather(world)
	for entry: Dictionary in roster:
		var holder: GameEntity = entry.holder
		var effect: Effect = entry.effect
		var plate := Plate.new(event, holder)
		if not effect.engages(plate):
			continue
		var holster: Array[Event] = []
		await _conductor.run(effect, plate, holster)
		for held: Event in holster:
			await fire(held)


# ── The gather (§12) ───────────────────────────────────────────────────────────────────
# Ordering is a two-tier lexicographic comparator, in one place, at the gather: a
# holder's bucket decides first, the bucket's key decides within. One principle closes
# every side tie: the player's holders order before the enemy's — hand position, order
# of death, and slot order are per-side keys; turn order interleaves the sides and
# leaves no tie.

func _gather(world: World) -> Array[Dictionary]:
	var holders: Array[GameEntity] = []
	# 1. The Game — a single holder, no key.
	holders.append(world.game)
	# 2. The Sides — player before enemy.
	var sides: Array[Side] = [world.player_side(), world.enemy_side()]
	for side: Side in sides:
		holders.append(side)
	# 3. Relics — acquisition order, player's before enemy's.
	for side: Side in sides:
		holders.append_array(side.get_container(&"relics").members)
	# 4. Cards in hand — hand position, player's before enemy's.
	for side: Side in sides:
		holders.append_array(side.get_container(&"hand").members)
	# 5. Fielded units and their statuses — turn order; a status resolves immediately
	# after its holding unit.
	for unit: Unit in turn_order(world):
		holders.append(unit)
		for member: GameEntity in unit.get_container(&"contained").members:
			if member is Status:
				holders.append(member)
	# 6. Board slots — slot order, per side, player's before enemy's.
	for side: Side in sides:
		holders.append_array(side.get_container(&"board").members)
	# 7. Graveyard units — order of death, player's before enemy's.
	for side: Side in sides:
		holders.append_array(side.get_container(&"graveyard").members)

	var roster: Array[Dictionary] = []
	for holder: GameEntity in holders:
		for effect: Effect in holder.effects:
			roster.append({"holder": holder, "effect": effect})
	return roster


# ── Turn order ─────────────────────────────────────────────────────────────────────────
# The activation comparator (Combat Frame §6): speed descending; ties to the player's
# units; ties then to forward depth — the unit furthest forward on its own half first;
# ties then to row order. Acceptance standard met: reproduces the pre-nuke ordering
# (speed desc → player first → forward column depth desc → row desc), with the slot's
# reading rank closing the total order. THE single definition — the clock and the
# turn-order display walk this same list.

static func turn_order(world: World) -> Array[Unit]:
	var keyed: Array[Array] = []
	var sides: Array[Side] = [world.player_side(), world.enemy_side()]
	for side_index: int in sides.size():
		var board: EntityContainer = sides[side_index].get_container(&"board")
		for slot_rank: int in board.members.size():
			var slot := board.members[slot_rank] as Slot
			var slotted: EntityContainer = slot.get_container(&"slotted_unit")
			for position: int in slotted.members.size():
				var unit := slotted.members[position] as Unit
				if unit == null:
					continue
				var forward_depth: int = slot.col if side_index == 0 \
						else BoardGeometry.COLS - 1 - slot.col
				keyed.append([-unit.get_stat(&"speed"), side_index, -forward_depth,
						-slot.row, slot_rank, position, unit])
	keyed.sort()
	var order: Array[Unit] = []
	for entry: Array in keyed:
		order.append(entry[6] as Unit)
	return order
