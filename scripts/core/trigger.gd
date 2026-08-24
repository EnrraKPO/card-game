class_name Trigger
extends RefCounted

# The trigger (Core System Design §9): it decides engagement. It holds its axial event
# condition — events are the thing listened to — then its further conditions in two typed
# lists, sorted at parse by family: EventDataConditions, and entity entries. The trigger
# holds when its event condition and both lists hold; an empty list holds vacuously. Each
# list carries its own policy, `all` or `any`, across its members.
#
# The trigger owns the fetch: its walk reads each entry's route, gathers the yield, and
# hands each entity to the entry's conditions. EventDataConditions carry no route and
# receive the occasion.
#
# The route list is closed: `source` — the occasion's source, a set of one; `holder` —
# the plate's holder, a set of one; `eventdata` — the entities of every EntityEventData
# on the occasion, pooled; a role name in its place yields that role's entities, an
# absent role the empty set; `world` — every entity that exists.


# An entity entry: a route, a list of conditions, and a negate. Its conditions are
# conjoined per entity, and the entry's fold is ANY: the entry holds when some entity of
# the route's yield satisfies every condition. The negate inverts that folded answer,
# turning the existential claim universal.
class EntityEntry:
	extends RefCounted
	var route: StringName = &""
	var conditions: Array[EntityCondition] = []
	var negate: bool = false

	func holds(plate: Plate) -> bool:
		var found := false
		for subject: GameEntity in _yield_route(plate):
			var all_hold := true
			for condition: EntityCondition in conditions:
				if not condition.holds(plate, subject):
					all_hold = false
					break
			if all_hold:
				found = true
				break
		return found != negate

	func _yield_route(plate: Plate) -> Array[GameEntity]:
		match route:
			&"source":
				var source: Array[GameEntity] = []
				if plate.occasion.source != null:
					source.append(plate.occasion.source)
				return source
			&"holder":
				var holder: Array[GameEntity] = [plate.holder]
				return holder
			&"world":
				return plate.world().all_entities()
			&"eventdata":
				var pooled: Array[GameEntity] = []
				for component: EventData in plate.occasion.components_of(EntityEventData):
					pooled.append_array((component as EntityEventData).entities)
				return pooled
			_:
				# A role name: that role's entities; a role absent from the occasion
				# yields the empty set.
				var of_role: Array[GameEntity] = []
				for component: EventData in plate.occasion.components_of(EntityEventData):
					var entities := component as EntityEventData
					if entities.role == route:
						of_role.append_array(entities.entities)
				return of_role


# The axial event condition: the occasion's name.
var event: StringName = &""

var eventdata_policy: StringName = &"all"
var eventdata_conditions: Array[EventDataCondition] = []

var entity_policy: StringName = &"all"
var entity_entries: Array[EntityEntry] = []


func holds(plate: Plate) -> bool:
	if plate.occasion.name != event:
		return false
	if not _fold_eventdata(plate):
		return false
	return _fold_entries(plate)


func _fold_eventdata(plate: Plate) -> bool:
	if eventdata_conditions.is_empty():
		return true
	for condition: EventDataCondition in eventdata_conditions:
		var held := condition.holds(plate, plate.occasion)
		if eventdata_policy == &"any" and held:
			return true
		if eventdata_policy == &"all" and not held:
			return false
	return eventdata_policy == &"all"


func _fold_entries(plate: Plate) -> bool:
	if entity_entries.is_empty():
		return true
	for entry: EntityEntry in entity_entries:
		var held := entry.holds(plate)
		if entity_policy == &"any" and held:
			return true
		if entity_policy == &"all" and not held:
			return false
	return entity_policy == &"all"
