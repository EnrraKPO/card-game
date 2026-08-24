class_name StatMutationProcedure
extends EngineProcedure

# Applies the delta to the target's stat (Mutation System Design §7). Serves stat
# changes, mana refill, exhaustion. The committed value is bounded by the fact's
# arithmetic in the WriteAuthority; the authority's fact events (died among them) travel
# back by return.


static func resolve(request: StatMutationRequest) -> Array[Event]:
	return apply(request.target, request.stat, request.delta, request)


# The combat-visible unit stats whose changes cue presentation — resource machinery
# (mana, tapping, draws) presents through its own surfaces, not as unit flourishes.
const CUED_STATS: Array[StringName] = [&"health", &"max_health", &"attack", &"speed",
		&"shield"]


static func apply(target: GameEntity, stat: StringName, delta: int,
		_context: EngineRequest) -> Array[Event]:
	var events: Array[Event] = []
	WriteAuthority.stat_write(target, stat, target.get_stat(stat) + float(delta), events)
	# Its cue at commit (MSD s10): a health raise reads as a heal; other visible unit
	# stats read as buff/debuff by sign.
	if target is Unit and delta != 0 and CUED_STATS.has(stat):
		var visual: StringName
		if stat == &"health" and delta > 0:
			visual = &"heal"
		elif stat == &"shield" and delta > 0:
			visual = &"shield_restored"   # the old routing: a shield raise is its own read
		elif delta > 0:
			visual = &"buff"
		else:
			visual = &"debuff"
		target.world.outlet.cue(visual, target, absf(float(delta)))
	return events
