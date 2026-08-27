class_name TargetResolver
extends RefCounted

# The target resolver (Core System Design §4): elects the recipients of an effect's
# payload. Inputs: the plate — occasion and holder, world reached through the holder —
# plus each candidate as the typed subject. Structure: conditions, then decision —
# conditions narrow the world to eligible candidates; the decision picks among them.
#
# Two phases. Resolve — side-effect-free: conditions applied, the field narrowed as far
# as determinism reaches, nothing committed; any reader may run it at any moment (the
# target poll, the preview world, the greyout). Engage — committing: unknowns settle
# once, in the live flow. An empty election ends the delivery; a declined pick yields an
# empty election.

var conditions: Array[EntityCondition] = []
var decision: Decision = null


func _init(p_conditions: Array[EntityCondition], p_decision: Decision) -> void:
	conditions = p_conditions
	decision = p_decision


func resolve(plate: Plate) -> Array[GameEntity]:
	return decision.resolve(plate, _narrow(plate))


func engage(plate: Plate) -> Array[GameEntity]:
	return await decision.engage(plate, _narrow(plate))


func _narrow(plate: Plate) -> Array[GameEntity]:
	var eligible: Array[GameEntity] = []
	for candidate: GameEntity in plate.world().all_entities():
		var passes := true
		for condition: EntityCondition in conditions:
			if not condition.holds(plate, candidate):
				passes = false
				break
		if passes:
			eligible.append(candidate)
	return eligible


# Automatic targeting of the Game — the Card type's play-targeting fact (Core §5).
# An effect authored without a targeting block falls back to the AutoResolver instead
# (Core §4).
static func game_default() -> TargetResolver:
	return TargetResolver.new([], GameDecision.new())


# The standing read composed as Core §3 states it: the entity's housing's owner's
# coordinate, as a board address — Vector3i(-1,-1,-1) for an entity standing nowhere.
static func standing_address(entity: GameEntity) -> Vector3i:
	var housing: EntityContainer = entity.housing
	var slot: Slot = null
	if entity is Slot:
		slot = entity as Slot
	elif housing != null and housing.name == &"slotted_unit" and housing.owner is Slot:
		slot = housing.owner as Slot
	if slot == null:
		return Vector3i(-1, -1, -1)
	return entity.world.board_manager.address_of(slot)
