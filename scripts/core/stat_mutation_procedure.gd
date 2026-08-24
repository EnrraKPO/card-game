class_name StatMutationProcedure
extends EngineProcedure

# Applies the delta to the target's stat (Mutation System Design §7). Serves stat
# changes, mana refill, exhaustion. The committed value is bounded by the fact's
# arithmetic in the WriteAuthority; the authority's fact events (died among them) travel
# back by return.


static func resolve(request: StatMutationRequest) -> Array[Event]:
	return apply(request.target, request.stat, request.delta, request)


static func apply(target: GameEntity, stat: StringName, delta: int,
		_context: EngineRequest) -> Array[Event]:
	var events: Array[Event] = []
	WriteAuthority.stat_write(target, stat, target.get_stat(stat) + float(delta), events)
	return events
