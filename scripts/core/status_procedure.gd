class_name StatusProcedure
extends EngineProcedure

# Resolves a status grant (Kind Rosters §4): a target not carrying the status
# has the object minted and inserted into its `contained`; a target already carrying it
# has the stacks added. The carried check reads the target's `contained` for a Status of
# the id, by checked downcast (Core §9).
#
# The minted status's starting stacks are its construction seed (genesis-is-construction
# extends to existence that begins mid-play); later grants go through the stat write.
# Its allegiance is stamped the target's — it lives on the target's side of the world
# (BRIEFS.html B20, flagged for ruling).


static func resolve(request: StatusRequest) -> Array[Event]:
	var events: Array[Event] = []
	var target: GameEntity = request.target
	var contained: EntityContainer = target.get_container(&"contained")
	for member: GameEntity in contained.members:
		if member is Status and (member as Status).status_id == request.status_id:
			WriteAuthority.stat_write(member, &"stacks",
					member.get_stat(&"stacks") + float(request.stacks), events, request)
			# The cue's recipient is the STATUS entity — it is what changed, and its pip
			# is its registered presentation surface (R14); identity rides the reference.
			target.world.outlet.cue(&"status_applied", member, float(request.stacks))
			return events
	var status: Status = ContentLibrary.build_status(request.status_id, target.allegiance)
	if status == null:
		# An unregistered id mints bare — a plain stacks marker (B33).
		status = Status.new(request.status_id, target.allegiance)
	status.seed_stat(&"stacks", float(request.stacks))
	WriteAuthority.mint(target.world, status)
	WriteAuthority.insert(contained, status)
	target.world.outlet.cue(&"status_applied", status, float(request.stacks))
	return events
