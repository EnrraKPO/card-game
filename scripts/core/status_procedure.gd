class_name StatusProcedure
extends EngineProcedure

# Resolves a status grant (Mutation System Design §7): a target not carrying the status
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
					member.get_stat(&"stacks") + float(request.stacks), events)
			return events
	var status := Status.new(request.status_id, target.allegiance)
	status.seed_stat(&"stacks", float(request.stacks))
	WriteAuthority.mint(target.world, status)
	WriteAuthority.insert(contained, status)
	return events
