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
var rng: RandomNumberGenerator = null


func _init(p_seed: int) -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = p_seed
	outlet = PresentationOutlet.new()
	picker = TargetPicker.new()
	cascade = CombatCascade.new(self)
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
