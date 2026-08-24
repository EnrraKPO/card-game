class_name World
extends RefCounted

# The world (Core System Design §1): the object entities live in. It embeds the
# BoardManager (§3), owns the presentation outlet and the seeded rng, and is what
# simulation copies. The world holds the Game as a plain member; the Game houses the two
# Sides in its container `sides` — player before enemy (Mutation §12) — and every other
# entity is reached through the containers already stated.
#
# Construction births the world's fixed skeleton whole — the Game, the two Sides, both
# halves' slots (§3) — before any event can fire; genesis then builds the fight's
# starting entities into their containers directly (Mutation §13). The outlet is born
# deaf; the live fight hands its presenter in at the reconnection seam (Mutation §10).

var game: Game = null
var board_manager: BoardManager = null
var outlet: PresentationOutlet = null
var picker: TargetPicker = null
var cascade: CombatCascade = null
var clock: CombatClock = null
var rng: RandomNumberGenerator = null
var seed_value: int = 0


func _init(p_seed: int) -> void:
	seed_value = p_seed
	rng = RandomNumberGenerator.new()
	rng.seed = p_seed
	outlet = PresentationOutlet.new()
	picker = TargetPicker.new()
	cascade = CombatCascade.new(self)
	clock = CombatClock.new(self)
	game = Game.new()
	WriteAuthority.mint(self, game)
	var sides_container: EntityContainer = game.get_container(&"sides")
	var sides: Array[Side] = []
	for i: int in 2:
		var side := Side.new()
		WriteAuthority.mint(self, side)
		WriteAuthority.insert(sides_container, side)
		sides.append(side)
	board_manager = BoardManager.new()
	board_manager.birth(self, sides)


# The two sides by their standing order (Mutation §12: player before enemy). The sides
# container's order is the identity — member 0 is the player's side, member 1 the enemy's.
func player_side() -> Side:
	return game.get_container(&"sides").members[0] as Side


func enemy_side() -> Side:
	return game.get_container(&"sides").members[1] as Side


# Every entity that exists (Core §9's `world` route; the resolver's candidate field):
# the ownership tree walked whole — the Game, then depth-first through every entity's
# containers, in declaration order. Deterministic on every re-run.
func all_entities() -> Array[GameEntity]:
	var out: Array[GameEntity] = []
	_collect(game, out)
	return out


func _collect(entity: GameEntity, out: Array[GameEntity]) -> void:
	out.append(entity)
	for container: EntityContainer in entity.get_container_list():
		for member: GameEntity in container.members:
			_collect(member, out)


# ── The copy (Core §1: the world is what simulation copies) ───────────────────────────
# A twin world: the skeleton born fresh, every housed entity cloned into the twin's
# corresponding container, both ends of every housing relation remapped by
# reconstruction, allegiance remapped to the twin's sides. Stats copy by value; effects,
# abilities, and identity are the shared stateless definitions (Mutation §4). The twin
# is born deaf (the base outlet), declining (the base picker), and with its own rng
# seeded from this world's seed — repeatable in its own right, structurally unable to
# touch the live streams (B33).

func copy() -> World:
	var twin := World.new(seed_value)
	twin.game.copy_facts_from(game)
	var sides: Array[Side] = [player_side(), enemy_side()]
	var twin_sides: Array[Side] = [twin.player_side(), twin.enemy_side()]
	for i: int in 2:
		twin_sides[i].copy_facts_from(sides[i])
		for container_name: StringName in [&"deck", &"hand", &"graveyard", &"relics"]:
			for member: GameEntity in sides[i].get_container(container_name).members:
				var clone: GameEntity = _clone(member, twin, twin_sides[i])
				WriteAuthority.insert(twin_sides[i].get_container(container_name), clone)
		var board: EntityContainer = sides[i].get_container(&"board")
		for slot_index: int in board.members.size():
			var slot := board.members[slot_index] as Slot
			var twin_slot := twin_sides[i].get_container(&"board").members[slot_index] as Slot
			for member: GameEntity in slot.get_container(&"slotted_unit").members:
				var clone: GameEntity = _clone(member, twin, twin_sides[i])
				WriteAuthority.insert(twin_slot.get_container(&"slotted_unit"), clone)
	return twin


func _clone(entity: GameEntity, twin: World, twin_side: Side) -> GameEntity:
	var clone: GameEntity
	if entity is Unit:
		var unit := Unit.new(twin_side, (entity as Unit).is_building)
		unit.is_king = (entity as Unit).is_king
		unit.main_action = (entity as Unit).main_action
		clone = unit
	elif entity is Spell:
		clone = Spell.new(twin_side)
	elif entity is Relic:
		clone = Relic.new(twin_side)
	elif entity is Status:
		clone = Status.new((entity as Status).status_id, twin_side)
	else:
		clone = GameEntity.new()
	clone.copy_facts_from(entity)
	WriteAuthority.mint(twin, clone)
	for member: GameEntity in entity.get_container(&"contained").members:
		WriteAuthority.insert(clone.get_container(&"contained"),
				_clone(member, twin, twin_side))
	return clone
