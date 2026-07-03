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
# The CURRENT shield pool (floors at 0). Distinct from SHIELD below: "shield" has always meant
# the per-round base (what restore_shield refills to), so the live pool gets its own name —
# one word must never mean two stats.
const SHIELD_POOL := &"shield_pool"

# ── Stats: additive modifiers on a CardInstance (fold into get_attribute at read time) ──
const ATTACK := &"attack"
const SPEED := &"speed"
const COST := &"cost"
const MAX_HEALTH := &"max_health"
const SHIELD := &"shield"   # per-round base shield (raises what each round's refill restores)

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


# Effect-attribute name → the stat it lands as. The two authored names with a distinct
# resolution form map to their stat ("health" signed/shield-bypassing, "damage_taken" the
# shield-first attack form); any other attribute is an additive modifier under its own name.
# Owned here so the vocabulary and its translation live in one file (used by EffectSystem).
static func stat_for_attribute(attr: String) -> StringName:
	match attr:
		"health":       return HEALTH
		"damage_taken": return DAMAGE
	return StringName(attr)


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
