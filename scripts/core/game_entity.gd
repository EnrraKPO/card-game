class_name GameEntity
extends RefCounted

# The root of the entity hierarchy (Core System Design §1). Every GameEntity holds effects,
# bears stats, holds a container map declaring `contained` (§2), bears a back-reference to
# the world it lives in, and bears its allegiance — the Side it belongs to, stamped at
# construction as a birth fact and never rewritten (Core §1).
#
# All up/back-references (world, allegiance, housing) are weak: the ownership tree —
# world → Game → containers → members — holds the strong references, so entities die with
# the world that owns them. World copies remap both ends of every housing relation (§2).

# Identity (envelope A7): the authored id and the display name. Empty on machinery-born
# entities the envelope never dressed (slots, sides, the Game).
var id: StringName = &""
var display_name: String = ""

# Effects this entity holds (Mutation §2: an effect is a rule of the game).
var effects: Array[Effect] = []

# The ability names this entity bears (Core §7): the ask capability — `use_ability` may
# be fired at the holder carrying one of these names. Appended by the ability expansion.
var abilities: Array[StringName] = []

var _world_ref: WeakRef = null
var _allegiance_ref: WeakRef = null
var _housing_ref: WeakRef = null

# Stats borne by this entity: id → value, one entry per declared id, all seeded 0.0 at
# construction until seeded from the authored form (§5) or genesis. Written ONLY by
# WriteAuthority.stat_write (Mutation §8) and, at construction, by seed_stat.
var _stats: Dictionary[StringName, float] = {}

# The container map (§2): name → EntityContainer, one entry per declared name.
var _containers: Dictionary[StringName, EntityContainer] = {}


func _init(p_allegiance: Side = null) -> void:
	if p_allegiance != null:
		_allegiance_ref = weakref(p_allegiance)
	for stat_id: StringName in _declared_mutable_stats() + _declared_readonly_stats():
		_stats[stat_id] = 0.0
	for container_name: StringName in _declared_containers():
		_containers[container_name] = EntityContainer.new(self, container_name)


# ── The back-references ────────────────────────────────────────────────────────────────

# The world this entity lives in (§1). Stamped by WriteAuthority.mint — existence in a
# world is that stamp. Null before minting.
var world: World:
	get: return _world_ref.get_ref() if _world_ref != null else null

# The allegiance fact (Core §1): the Side this entity belongs to. A birth fact — stamped at
# construction, never rewritten. Null states the entity belongs to no side (the Game).
var allegiance: Side:
	get: return _allegiance_ref.get_ref() if _allegiance_ref != null else null

# The container housing this entity (§2). Maintained by the membership primitives (insert,
# remove) — the only writers of container members — on every write. Null = unhoused: a
# newly minted entity, or the Game, held by the world as a plain member (§1).
var housing: EntityContainer:
	get: return _housing_ref.get_ref() if _housing_ref != null else null


# ── Stats (§9) ─────────────────────────────────────────────────────────────────────────
# Each type declares its stat ids in two lists: public mutable, and read-only. Validation
# runs twice: parse refuses an id the authored subject type does not declare; execution
# refuses at the concrete bearer — an unborne id, or a write to a read-only stat.

func _declared_mutable_stats() -> Array[StringName]:
	return []


func _declared_readonly_stats() -> Array[StringName]:
	return []


func bears_stat(stat_id: StringName) -> bool:
	return _stats.has(stat_id)


func stat_readonly(stat_id: StringName) -> bool:
	return _declared_readonly_stats().has(stat_id)


func get_stat(stat_id: StringName) -> float:
	if not _stats.has(stat_id):
		push_error("GameEntity: '%s' does not bear stat '%s'" % [get_class_label(), stat_id])
		return 0.0
	return _stats[stat_id]


# Construction-time seeding (§5: cost is "seeded from the authored form at construction";
# Mutation §13: genesis is construction, not mutation). Play-time changes go through
# WriteAuthority.stat_write — never through this.
func seed_stat(stat_id: StringName, value: float) -> void:
	if not _stats.has(stat_id):
		push_error("GameEntity: cannot seed unborne stat '%s' on '%s'" % [stat_id, get_class_label()])
		return
	_stats[stat_id] = value


# ── The container map (§2) ─────────────────────────────────────────────────────────────
# The two reads: fetch by name, and enumerate. GameEntity declares `contained`, so every
# entity bears it; the further names each type declares are the type's own statement.

func _declared_containers() -> Array[StringName]:
	return [&"contained"]


func get_container(container_name: StringName) -> EntityContainer:
	var found: EntityContainer = _containers.get(container_name)
	if found == null:
		push_error("GameEntity: '%s' declares no container '%s'" % [get_class_label(), container_name])
	return found


func get_container_list() -> Array[EntityContainer]:
	var out: Array[EntityContainer] = []
	for c: EntityContainer in _containers.values():
		out.append(c)
	return out


# The world-copy's fact transfer (Core §1): stats by value; identity, effects, and
# abilities are the shared stateless definitions — the arrays duplicate, their members
# do not.
func copy_facts_from(source: GameEntity) -> void:
	id = source.id
	display_name = source.display_name
	_stats = source._stats.duplicate()
	effects = source.effects.duplicate()
	abilities = source.abilities.duplicate()


# The type's name for error text — script class_name, cold-readable in a refusal message.
func get_class_label() -> String:
	var script: Script = get_script()
	return script.get_global_name() if script != null else "GameEntity"
