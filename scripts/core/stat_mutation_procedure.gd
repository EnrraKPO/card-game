class_name StatMutationProcedure
extends EngineProcedure

# Applies the delta to the target's stat (Kind Rosters §4). Serves stat
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
		context: EngineRequest) -> Array[Event]:
	var events: Array[Event] = []
	WriteAuthority.stat_write(target, stat, target.get_stat(stat) + float(delta), events,
			context)
	# Its cue at commit (MSD s10): a health raise reads as a heal; other visible unit
	# stats read as buff/debuff by sign. The heal/buff/debuff cues utter the stat's name
	# as the variant so presentation can land the show on the stat that moved.
	if target is Unit and delta != 0 and CUED_STATS.has(stat):
		var visual: StringName
		var variant: StringName = stat
		if stat == &"health" and delta > 0:
			visual = &"heal"
		elif stat == &"shield" and delta > 0:
			visual = &"shield_restored"   # the old routing: a shield raise is its own read
			variant = &""
		elif delta > 0:
			visual = &"buff"
		else:
			visual = &"debuff"
		target.world.outlet.cue(visual, target, absf(float(delta)), variant)
	return events
