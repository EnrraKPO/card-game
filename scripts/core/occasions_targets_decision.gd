class_name OccasionsTargetsDecision
extends Decision

# The occasion's targets (Core §4): the stock form of a substantive effect — it takes the
# occasion's elected targets (EntityEventData, role `targets`) as its own, kept to those
# still in the narrowed field. Deterministic.


func resolve(plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	var elected: Array[GameEntity] = []
	for component: EventData in plate.occasion.components_of(EntityEventData):
		var entities := component as EntityEventData
		if entities.role != &"targets":
			continue
		for entity: GameEntity in entities.entities:
			if candidates.has(entity) and not elected.has(entity):
				elected.append(entity)
	return elected
