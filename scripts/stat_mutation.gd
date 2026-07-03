class_name StatMutation
extends RefCounted

# The ONE request shape for changing a game-state number. Nothing in the game writes a stat
# directly — combat, effects, hooks and screens build one of these and submit it to Resolver
# (the single writer), then act on the outcome. See Resolver for the application rules.
#
# `stat` is the consistent vocabulary shared by every stat-touching system: these are the SAME
# names effect attributes use, CardInstance.modifiers keys on, and DeckCard override fields
# carry — one language, no translation layer anywhere.
#
# `channel` is provenance metadata: what KIND of procedure spawned this mutation. Nothing
# consumes it yet — it exists so interception can subscribe selectively later ("block attack
# damage, ignore poison ticks") without reshaping this contract. NOTE: events are never
# inferred from mutations — "an attack happened" is a Trigger broadcast that fires whether or
# not any mutation follows (a whiff still counts as being attacked).

# ── Stats: live pools on a CardInstance ──
# Signed direct health change: positive heals (clamped to max), negative wounds DIRECTLY,
# bypassing shield (poison, sacrifice effects).
const HEALTH := &"health"
# Attack-form harm: a positive magnitude, resolved shield-first. HOW it lands (shield absorbs,
# the rest wounds health) is the Resolver's knowledge — no caller knows shields exist.
const DAMAGE := &"damage"
# Current shield pool delta. (As a modifier/override field this same name is the per-round
# base shield instead — same word, resolved by target kind.)
const SHIELD := &"shield"

# ── Stats: additive modifiers on a CardInstance (fold into get_attribute at read time) ──
const ATTACK := &"attack"
const SPEED := &"speed"
const COST := &"cost"
const MAX_HEALTH := &"max_health"

# A DeckCard target instead treats `stat` as the card-definition FIELD to bump permanently
# ("attack"/"health"/"speed"/"shield" — see DeckCard.UPGRADABLE and the "?" event).

# ── Channels (provenance) ──
const CH_ATTACK := &"attack"   # a unit's strike
const CH_EFFECT := &"effect"   # a card/status/relic/upgrade effect
const CH_SYSTEM := &"system"   # engine bookkeeping (round shield refresh, king persistence, setup)

var target: Object = null          # CardInstance (live stats) or DeckCard (persistent override)
var stat: StringName = HEALTH
var amount: int = 0
var source: CardInstance = null    # who caused it (null for system mutations)
var channel: StringName = CH_EFFECT


static func make(p_target: Object, p_stat: StringName, p_amount: int,
		p_source: CardInstance = null, p_channel: StringName = CH_EFFECT) -> StatMutation:
	var m := StatMutation.new()
	m.target = p_target
	m.stat = p_stat
	m.amount = p_amount
	m.source = p_source
	m.channel = p_channel
	return m


# The pending strike of an attack. Combat builds this BEFORE the ON_ATTACK dispatch and hangs
# it on the context (EffectContext.pending) so effects can rewrite the amount mid-flight
# (arbitration — see "outgoing_damage" in EffectSystem._apply), then submits whatever is left.
# Never negative: a fully blocked strike is 0, not a heal.
static func damage(p_target: Object, p_amount: int, p_source: CardInstance) -> StatMutation:
	return make(p_target, DAMAGE, maxi(0, p_amount), p_source, CH_ATTACK)
