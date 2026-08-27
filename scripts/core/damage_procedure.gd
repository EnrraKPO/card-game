class_name DamageProcedure
extends EngineProcedure

# Resolves damage: shield absorbs first, remainder to health (Kind Rosters §4).
# Applied by the strike procedure inside a connecting strike — same body, same events,
# the context request's provenance carried whole; a burn's damage would carry the burn
# kind the same way.
#
# The damaged event: source the request's source — the holder of the effect that minted
# the request — target the damaged entity in the core (Core §8), the request at hand
# stamped as RequestEventData, the committed writes riding as
# StatMutationEventData; the authority's died follows it in return order.


static func resolve(request: DamageRequest) -> Array[Event]:
	return apply(request.target, request.amount, request)


static func apply(target: GameEntity, amount: int, context: EngineRequest) -> Array[Event]:
	var authority_events: Array[Event] = []
	var dealt: float = float(amount)
	var shield: float = target.get_stat(&"shield")
	var absorbed: float = minf(shield, dealt)
	if absorbed > 0.0:
		WriteAuthority.stat_write(target, &"shield", shield - absorbed, authority_events,
				context)
		target.world.outlet.cue(&"shield_hit", target, absorbed)   # its cue at commit (MSD s10)
	var remainder: float = dealt - absorbed
	if remainder > 0.0:
		WriteAuthority.stat_write(target, &"health",
				target.get_stat(&"health") - remainder, authority_events, context)
		target.world.outlet.cue(&"health_damage", target, remainder)   # its cue at commit
	var damaged := Event.new(&"damaged", context.source, target)
	damaged.components.append(RequestEventData.new(context))
	if absorbed > 0.0:
		damaged.components.append(StatMutationEventData.new(&"shield", -roundi(absorbed)))
	if remainder > 0.0:
		damaged.components.append(StatMutationEventData.new(&"health", -roundi(remainder)))
	var events: Array[Event] = [damaged]
	events.append_array(authority_events)
	return events
