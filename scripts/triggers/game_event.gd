class_name GameEvent
extends RefCounted

# One thing HAPPENING that effects may react to. Every event has the same abstract shape:
# an id, an ORIGIN (the unit the event emanates from — the striker, the dying unit, the
# played card) and, for dual events, a DESTINATION (the unit on the receiving end — the
# unit being struck). Effects never see event-specific participant names ("attacker",
# "attack target"); trigger resolvers gate on origin/destination uniformly (see
# TriggerResolver). Emission points construct these; nothing else does.
#
# Simple events (origin only): play, death, act, turn_start, turn_end.
# Dual events (origin + destination): attack (the swing, fired before the damage
# resolves), struck (fired after the damage resolves — whether or not any landed),
# kill (a unit died — origin = killer unit (attacks only), destination = the corpse;
# fired just before `death`, both while the corpse is still on the board),
# dodge and crit (the avoid and the critical). NOTHING EMITS THESE TODAY — 2026-08-13
# ruling: both rolls gated on the cursed channel and were nuked with it, as was the blow
# news that broadcast them. The ids survive as vocabulary for the sanctioned re-pitch.
# FRAMING convention: struck/kill/dodge are framed from the AFFECTED party's perspective
# ("it was struck / died / dodged"); attack and crit from the ACTING party's ("it attacked
# / landed a crit").

var id: StringName = &""
var origin: CardInstance = null
var destination: CardInstance = null
# NUKED (2026-08-13 ruling): cause_kind was the cursed channel vocabulary riding on the
# event ("the KIND of blow: attack/effect"), and cause_id its companion. Nothing populates
# a kill's provenance until the sanctioned write form carries one.


static func make(p_id: StringName, p_origin: CardInstance, p_destination: CardInstance = null) -> GameEvent:
	var e := GameEvent.new()
	e.id = p_id
	e.origin = p_origin
	e.destination = p_destination
	return e


# The `kill` event: origin = the killer UNIT, destination = the killed unit (the corpse,
# still on board). A dual event. The cause provenance it also carried was nuked with the
# channel — 2026-08-13 ruling.
static func kill(p_killer: CardInstance, p_killed: CardInstance) -> GameEvent:
	return make(&"kill", p_killer, p_killed)
# (The legacy single-subject bridge — subject() — was deleted 2026-08-11 with its last
# consumer: the design has no single-subject perspective, only origin/destination and the
# framing convention above.)
