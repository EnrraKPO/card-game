class_name PayCostProcedure
extends EngineProcedure

# Commits the cost (Mutation System Design §7): mana down on the target side, tap spent
# on the source — and produces the engaged event, play_engaged for the play,
# ability_used for an ability use, the ability's name carried forward as NameEventData
# role `ability` (Core §7). The engaged event's source is the asked entity, the request
# at hand stamped as RequestEventData (A19); the elected targets are appended by the
# delivery.
#
# Affordability is the trigger's baked condition, upstream — this procedure commits what
# was asked.


static func resolve(request: PayCostRequest) -> Array[Event]:
	var events: Array[Event] = []
	var side: GameEntity = request.target
	if request.mana != 0:
		WriteAuthority.stat_write(side, &"mana",
				side.get_stat(&"mana") - float(request.mana), events, request)
	if request.tap != 0:
		WriteAuthority.stat_write(request.source, &"tapped",
				request.source.get_stat(&"tapped") + float(request.tap), events, request)
	var engaged := Event.new(request.engaged_name, request.source, request.target)
	engaged.components.append(RequestEventData.new(request))
	if request.ability != &"":
		engaged.components.append(NameEventData.new(&"ability", request.ability))
	events.append(engaged)
	return events
