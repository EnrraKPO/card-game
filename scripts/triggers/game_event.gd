class_name GameEvent
extends RefCounted

# One thing HAPPENING that effects may react to. Every event has the same abstract shape:
# an id, an ORIGIN (the unit the event emanates from — the striker, the dying unit, the
# played card) and, for dual events, a DESTINATION (the unit on the receiving end — the
# unit being struck). Effects never see event-specific participant names ("attacker",
# "attack target"); trigger resolvers gate on origin/destination uniformly (see
# TriggerResolver). Emission points construct these; nothing else does.
#
# Simple events (origin only): play, death, activate, turn_start, turn_end.
# Dual events (origin + destination): attack (the swing, fired before the damage
# resolves), struck (fired after the damage resolves — whether or not any landed).

var id: StringName = &""
var origin: CardInstance = null
var destination: CardInstance = null


static func make(p_id: StringName, p_origin: CardInstance, p_destination: CardInstance = null) -> GameEvent:
	var e := GameEvent.new()
	e.id = p_id
	e.origin = p_origin
	e.destination = p_destination
	return e


# The unit the event is "about" from the legacy single-subject perspective — the bridge to
# the pieces that still think in one subject: EffectContext.subject (SUBJECT targeting), the
# run-level perspective card, and the decay gate. For `struck` that was always the unit
# taking the hit (the destination); for everything else it is the origin.
func subject() -> CardInstance:
	if id == &"struck" and destination != null:
		return destination
	return origin
