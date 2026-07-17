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
# resolves), struck (fired after the damage resolves — whether or not any landed),
# kill (a unit died — origin = killer unit (attacks only), destination = the corpse;
# fired just before `death`, both while the corpse is still on the board).

var id: StringName = &""
var origin: CardInstance = null
var destination: CardInstance = null
# Cause provenance — populated for the `kill` event (see combat kill emission). `cause_kind`
# is the KIND of blow (attack/effect), `cause_id` the specific one (a status id like "poison",
# else ""). Trigger resolvers gate the `kill` event on these (see TriggerResolver.Dual.cause).
var cause_kind: StringName = &""
var cause_id: StringName = &""


static func make(p_id: StringName, p_origin: CardInstance, p_destination: CardInstance = null) -> GameEvent:
	var e := GameEvent.new()
	e.id = p_id
	e.origin = p_origin
	e.destination = p_destination
	return e


# The `kill` event: origin = the killer UNIT (null unless the kill was an attack — an
# effect/poison kill credits no unit), destination = the killed unit (the corpse, still on
# board), plus the cause provenance. A dual event; subject() is the corpse (see below).
static func kill(p_killer: CardInstance, p_killed: CardInstance,
		p_cause_kind: StringName, p_cause_id: StringName) -> GameEvent:
	var e := make(&"kill", p_killer, p_killed)
	e.cause_kind = p_cause_kind
	e.cause_id = p_cause_id
	return e


# The unit the event is "about" from the legacy single-subject perspective — the bridge to
# the pieces that still think in one subject: EffectContext.subject (SUBJECT targeting), the
# run-level perspective card, and the decay gate. For `struck` that was always the unit
# taking the hit (the destination); for everything else it is the origin.
func subject() -> CardInstance:
	if (id == &"struck" or id == &"kill") and destination != null:
		return destination
	return origin
