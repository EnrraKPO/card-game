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
# `channel` is provenance metadata: what KIND of procedure spawned this mutation. Interception
# subscribes to it selectively — "block attack damage, ignore poison ticks" is an interceptor
# on stat `health` gated to channel `attack`. NOTE: events are never inferred from mutations —
# "an attack happened" is a Trigger broadcast that fires whether or not any mutation follows
# (a whiff still counts as being attacked).

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
# Status application: "apply `amount` stacks of `status_id` to the target". Routed through the
# Resolver like every other state write (single-writer rule), which is what makes stack counts
# interceptable ("statuses you apply gain +1 stack"). Floors at 0 like DAMAGE — an intercepted-
# away application applies nothing, never removes stacks.
const STATUS := &"status"
# A transient, never-stored quantity: the TARGET's dodge chance (integer percentage points) for
# one incoming attack, routed through the interception gate so a relic can rewrite it — "air
# units 3x dodge" (mul 3), "cancel enemy dodge" (mul 0). Built + intercepted in
# Resolver.dodge_chance and read straight back (never applied to any pool). Distinct from
# DODGE_BONUS below, which is the STORED additive modifier folded INTO this chance. Floors at 0.
const DODGE := &"dodge"

# ── Stats: additive modifiers on a CardInstance (fold into get_attribute at read time) ──
const ATTACK := &"attack"
const SPEED := &"speed"
const COST := &"cost"
const MAX_HEALTH := &"max_health"
const SHIELD := &"shield"   # per-round base shield (raises what each round's refill restores)
const DODGE_BONUS := &"dodge_bonus"   # additive dodge-chance bonus in percentage points (see Resolver.dodge_chance)

# A DeckCard target instead treats `stat` as the card-definition FIELD to bump permanently
# ("attack"/"health"/"speed"/"shield" — see DeckCard.UPGRADABLE and the "?" event).

# ── Stats: player-side resources (target is a CombatSide, not a card) ──
# "draw N": pull N cards deck→hand; floors at 0, stops at the pile — delta reports what
# actually moved. Interceptable ("your draws are doubled"), including turn-start draws
# (single-writer rule: every side write rides submit, channels keep provenance distinct).
const DRAW := &"draw"
# Random discard of N cards from the hand (floors at 0, stops at the hand; chosen-discard
# UI deliberately later). Discarded cards cease — no discard-pile zone exists.
const DISCARD := &"discard"
# Signed current-mana change. Floors at 0; NO cap at max_mana (settled: the pool may
# exceed max freely — a "gain 3 mana" at full mana is a real gain, not a clamp-away).
const MANA := &"mana"
# Additive max-mana change (the gauge's size). Floors at 0.
const MAX_MANA := &"max_mana"

# The side-stat vocabulary, as authored attribute strings — the load-time validation set
# (side stats require side targeting and vice versa; see Effect._validate_side_targets).
const SIDE_STATS: Array[String] = ["draw", "discard", "mana", "max_mana"]

static func is_side_stat(attr: String) -> bool:
	return SIDE_STATS.has(attr)

# ── Channels (provenance) ──
const CH_ATTACK := &"attack"   # a unit's strike
const CH_EFFECT := &"effect"   # a card/status/relic/upgrade effect
const CH_SYSTEM := &"system"   # engine bookkeeping (round shield refresh, king persistence, setup)
const CH_COST   := &"cost"     # paying a card/ability cost — distinct so a "mana gains doubled"
							   # interceptor can never double SPENDING

var target: Object = null          # CardInstance (live stats), CombatSide (player resources)
								   # or DeckCard (persistent override)
var stat: StringName = HEALTH
var amount: int = 0
var source: CardInstance = null    # who caused it (null for system mutations)
var channel: StringName = CH_EFFECT
# Provenance for the `kill` event (see Resolver kill-stamping + GameEvent). `channel` is
# the KIND of cause (attack/effect/…); `cause` is WHICH specific one — a status id for a
# tick ("poison"), else "". Together they answer "what killed this unit": an attack, or
# poison, or another effect. Set by the producing site (StatMutation.damage stamps the
# attack kind; EffectSystem stamps the status id for a status-held effect).
var cause: StringName = &""
# STATUS-form metadata: which status is being applied and with what duration override
# (`amount` carries the stack count — the interceptable magnitude, like every other form).
var status_id: String = ""
var status_duration: int = Effect.STATUS_DURATION_DEFAULT
# Marks the shield/health SHARE of a split hit (built inside Resolver._apply_damage). A
# portion is a reduction by construction: rewrites clamp it at <= 0 after every interceptor
# (mirroring the >= 0 re-floor on DAMAGE), so "take less" can zero a wound but never flip
# it into a heal or a shield gain.
var portion := false


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


# The strike of an attack: attack-channel damage from `p_source`. Interception happens inside
# Resolver.submit (INTERCEPTOR effects on the source/target rewriting the amount — e.g. Blind);
# the caller just submits and presents the outcome. Never negative: a fully blocked strike is
# 0, not a heal.
static func damage(p_target: Object, p_amount: int, p_source: CardInstance) -> StatMutation:
	return make(p_target, DAMAGE, maxi(0, p_amount), p_source, CH_ATTACK)


# A status application: `p_stacks` stacks of `p_status_id` onto the target. Submitted through
# the Resolver so interceptors can rewrite the stack count before it commits.
static func status_apply(p_target: Object, p_status_id: String, p_duration: int,
		p_stacks: int, p_source: CardInstance = null) -> StatMutation:
	var m := make(p_target, STATUS, maxi(0, p_stacks), p_source, CH_EFFECT)
	m.status_id = p_status_id
	m.status_duration = p_duration
	return m
