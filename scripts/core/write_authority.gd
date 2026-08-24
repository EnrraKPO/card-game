class_name WriteAuthority
extends RefCounted

# Every change to a game fact goes through the WriteAuthority (Mutation System Design §8).
# No bypass, from any origin. It performs writes and decides nothing. Static, matching the
# engine: requests are self-sufficient and all state lives in the world's facts, so one
# authority serves the live fight and every simulated world.
#
# Its primitives are exactly four — the stat write, container insert, container remove,
# and mint — each existing exactly once: a number (the stat write), a membership (insert,
# remove), an existence (mint). Per-container law stays above the primitives, in
# procedures. The membership primitives are the ONLY writers of container members, and
# they maintain the housed entity's back-reference on every write (Core §2).
#
# It owns each fact's arithmetic — floors, caps, whatever governs a specific fact's
# committed value — in exactly one place (_bound below). Arithmetic bounds the write's
# performance; it is not a decision.
#
# It may produce events on the writes it performs — health reaching zero produces
# `died`. A fact event exists only where content cares: none is issued ahead of need.
# Events travel by return: the caller's collection receives them.


# ── The stat write ─────────────────────────────────────────────────────────────────────
# Commits `value` to the entity's stat, bounded by the fact's arithmetic. Execution
# refuses at the concrete bearer — an unborne id, or a write to a read-only stat — loudly,
# committing nothing (Core §9). Fact events of the write append to `events`. Returns the
# committed value (the current value on refusal).
static func stat_write(entity: GameEntity, stat: StringName, value: float,
		events: Array[Event]) -> float:
	if not entity.bears_stat(stat):
		push_error("WriteAuthority: '%s' does not bear stat '%s' — write refused"
				% [entity.get_class_label(), stat])
		return 0.0
	if entity.stat_readonly(stat):
		push_error("WriteAuthority: stat '%s' on '%s' is read-only — write refused"
				% [stat, entity.get_class_label()])
		return entity.get_stat(stat)
	var previous: float = entity._stats[stat]
	var committed: float = _bound(stat, value)
	entity._stats[stat] = committed
	if stat == &"health" and previous > 0.0 and committed <= 0.0:
		events.append(Event.new(&"died", entity))
	return committed


# The per-fact arithmetic table. One place, growing as signed facts land:
#   · tapped floors at zero (Combat Frame §6).
static func _bound(stat: StringName, value: float) -> float:
	match stat:
		&"tapped":
			return maxf(0.0, value)
	return value


# ── The membership primitives ──────────────────────────────────────────────────────────
# One housing (Core §2): at any moment an entity is a member of exactly one container, or
# of none. A move is one PROCEDURE performing remove-from-housing then insert-at-
# destination — a primitive performs only its own half and refuses an ask that would
# break the invariant.

# Inserts the entity into the container's ordered members — at `index`, or appended when
# index is -1 — and stamps the entity's housing back-reference.
static func insert(container: EntityContainer, entity: GameEntity, index: int = -1) -> void:
	if entity.housing != null:
		push_error("WriteAuthority: entity is already housed in '%s' — insert into '%s' refused"
				% [entity.housing.name, container.name])
		return
	if index < 0:
		container.members.append(entity)
	else:
		container.members.insert(index, entity)
	entity._housing_ref = weakref(container)


# Removes the entity from the container's members and clears its housing back-reference.
static func remove(container: EntityContainer, entity: GameEntity) -> void:
	var at: int = container.members.find(entity)
	if at < 0:
		push_error("WriteAuthority: entity is not a member of '%s' — remove refused"
				% container.name)
		return
	container.members.remove_at(at)
	entity._housing_ref = null


# ── Mint ───────────────────────────────────────────────────────────────────────────────
# Existence (Mutation §8, §13): an entity exists in a world from the moment this stamps
# its world back-reference. Genesis and the BoardManager's birth mint every starting
# entity; the StatusProcedure mints existence that begins mid-play. The minted entity is
# unhoused until a membership write houses it.
static func mint(world: World, entity: GameEntity) -> GameEntity:
	entity._world_ref = weakref(world)
	return entity
