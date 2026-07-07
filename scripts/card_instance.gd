class_name CardInstance
extends RefCounted

# Fires on every current_health write (damage, healing, shield bleed-through, initial draw/reset).
# Combat connects this for the player King specifically to drive the header's live HP display (see
# [[header-system]]) — RunData.king_damage is only the POST-fight snapshot, so it can't be the
# source of a mid-fight signal; the board unit's live health is.
signal health_changed(current: int)

var data: CardData
var current_health: int : set = _set_current_health
var current_shield: int


func _set_current_health(v: int) -> void:
	current_health = v
	health_changed.emit(v)
var row: int = -1
var col: int = -1
var owner: int = -1  # 0 = player, 1 = enemy
var modifiers: Dictionary = {}  # attribute id -> cumulative int delta
# Charm ids attached to this card (display only — their mechanics are already baked into
# `data` by DeckCard.make_instance). Empty for enemies, kings, and tokens.
var charms: Array = []
# Live Statuses on this card (Array[StatusInstance]) — runtime buffs/debuffs/periodic effects
# applied during combat and removed on a timer. Never serialized (rebuilt each fight). Their
# STANDING effects fold into get_attribute via LiveEffects; TRIGGERED ones fire via
# EffectSystem.trigger.
var statuses: Array = []

# Set true for the round when this unit spent its attack to generate a card
# (see rook/building generation in combat.gd). Reset at the start of each round.
var attack_exhausted: bool = false
# On an ability's tray token (the card-shaped view of an activated ability), the unit that
# HOLDS the ability — activation acts as this unit (effect source) and pays its tap cost.
# Null on normal units.
var source_building: CardInstance = null
# On an ability's tray token, the ability being activated. Null on normal units.
var ability: AbilityData = null
# The ARMED autocast ability's id ("" = none) — set by the AbilityWidget toggle. A single field,
# so "max 1 armed per unit" is structural. Runtime-only (never serialized); survives tapping
# (the offer just isn't fireable until the round refresh). Read through armed_autocast().
var autocast_ability: String = ""

var is_spell: bool:
	get: return data != null and data.card_type == CardData.CardType.SPELL


static func from_data(card_data: CardData) -> CardInstance:
	var inst := CardInstance.new()
	inst.data = card_data
	inst.current_health = card_data.health
	inst.current_shield = card_data.shield
	return inst


# Returns the effective value of an attribute: base + this instance's accumulated WRITTEN
# modifiers (baked history from triggered effects / charms) + every live STANDING effect
# currently reaching this card — statuses, its own innate effects, and the run set, all
# through the ONE evaluator (LiveEffects), recomputed against current state on every read.
func get_attribute(attr: String) -> int:
	match attr:
		"health":     return current_health
		"max_health": return data.health + modifiers.get("max_health", 0) + LiveEffects.bonus(self, "max_health")
		"attack":     return data.attack + modifiers.get("attack",     0) + LiveEffects.bonus(self, "attack")
		"speed":      return data.speed  + modifiers.get("speed",      0) + LiveEffects.bonus(self, "speed")
		"cost":       return data.cost   + modifiers.get("cost",       0) + LiveEffects.bonus(self, "cost")
		"shield":     return current_shield
		# Read-only composition counts, so conditions can query merge room with the ordinary
		# attribute/comparator form (e.g. a pawn material: piece_count <= 1). Never modified.
		"piece_count":   return data.chess_pieces.size()
		"element_count": return data.elements.size()
		_:            return modifiers.get(attr, 0)


# Storage-level write for the additive-modifier bag. Called by Resolver ONLY — every stat
# change in the game routes through Resolver.submit (see Resolver); nothing else mutates
# these values directly. Damage/heal/shield forms live in the Resolver too.
func apply_modifier(attr: String, delta: int) -> void:
	modifiers[attr] = modifiers.get(attr, 0) + delta


func is_alive() -> bool:
	return current_health > 0


# The unit's current activated abilities — resolved at READ TIME like any stat: the card's
# base list (ability_ids, incl. the rook fallback) plus any held by active statuses (a status
# holding an ability makes it temporary by nature). No runtime write channel exists yet; when
# mutation becomes relevant it slots in here, beside the other components.
func ability_list() -> Array:
	var out: Array = []
	for ab_id: String in data.ability_ids():
		var ab := AbilityData.get_ability(ab_id)
		if ab != null:
			out.append(ab)
	for si: StatusInstance in statuses:
		for ab_id: String in si.data.abilities:
			var ab := AbilityData.get_ability(ab_id)
			if ab != null:
				out.append(ab)
	return out


# The armed autocast ability, resolved against the CURRENT ability list — a stale id (the
# granting status expired) reads as "nothing armed" without needing an eviction hook.
func armed_autocast() -> AbilityData:
	if autocast_ability.is_empty():
		return null
	for ab: AbilityData in ability_list():
		if ab.id == autocast_ability:
			return ab
	return null


# Whether at least one of this unit's abilities is currently offerable — a tap-costed ability of
# an already-tapped unit doesn't count (mana affordability is checked later, at cast time).
func has_available_abilities() -> bool:
	for ab: AbilityData in ability_list():
		if not (ab.tap and attack_exhausted):
			return true
	return false


# Swaps this unit's card identity in place (a material merged into its composition — see
# EffectHooks.deliver_material). Wounds carry over as a damage DELTA: merging upgrades a unit,
# it never heals it — and never kills it (floor 1 HP). Runtime modifiers, statuses, the charm
# list, the current shield pool, position and owner all stay. Per-card overrides and charm
# stat bakes on the OLD data do NOT transfer — the combined composition resolves to its
# authored/derived card (v1 rule). Health lands through the Resolver like every stat write.
func transform(new_data: CardData) -> void:
	if new_data == null:
		return
	var damage := get_attribute("max_health") - current_health
	data = new_data
	Resolver.set_health(self, maxi(1, get_attribute("max_health") - damage))


# ── Statuses ───────────────────────────────────────────────────────────────────────────

# Applies a status (by id) to this card, combining with an existing one of the same id per the
# status's stacking rule. `duration` defaults to the status's own (pass to override); a status
# whose kind is "combat" always lasts the whole fight regardless. See StatusData / StatusEngine.
func apply_status(status_id: String, duration: int = Effect.STATUS_DURATION_DEFAULT, stacks: int = 1, src: CardInstance = null) -> void:
	var sdata := StatusData.get_status(status_id)
	if sdata == null:
		return
	var existing := find_status(status_id)
	if existing == null or sdata.stacking == StatusData.STACK_INDEPENDENT:
		statuses.append(StatusInstance.make(sdata, _initial_remaining(sdata, duration), clampi(stacks, 1, sdata.max_stacks), src))
		return
	match sdata.stacking:
		StatusData.STACK_EXTEND:
			if sdata.decay == StatusData.DECAY_DURATION and existing.remaining != -1:
				existing.remaining += _resolved_duration(sdata, duration)
		StatusData.STACK_INTENSITY:
			existing.stacks = mini(existing.stacks + stacks, sdata.max_stacks)
			existing.remaining = _refreshed_remaining(existing, sdata, duration)
		_:   # STACK_REFRESH (default)
			existing.remaining = _refreshed_remaining(existing, sdata, duration)


func find_status(status_id: String) -> StatusInstance:
	for si: StatusInstance in statuses:
		if si.data.id == status_id:
			return si
	return null


func remove_status(status_id: String) -> void:
	statuses = statuses.filter(func(si: StatusInstance) -> bool: return si.data.id != status_id)


func clear_statuses() -> void:
	statuses.clear()


# The effective duration to apply: the caller's override, else the status's own default.
static func _resolved_duration(sdata: StatusData, duration: int) -> int:
	return duration if duration != Effect.STATUS_DURATION_DEFAULT else sdata.default_duration


# Initial `remaining` for a new instance: a countdown only for DECAY_DURATION; -1 (unused) for
# stack-decay / never-decay statuses, which don't use the timer.
static func _initial_remaining(sdata: StatusData, duration: int) -> int:
	if sdata.decay != StatusData.DECAY_DURATION:
		return -1
	return _resolved_duration(sdata, duration)


# Refreshed `remaining` on re-application: the longer of current and incoming for DECAY_DURATION;
# left as-is otherwise.
static func _refreshed_remaining(existing: StatusInstance, sdata: StatusData, duration: int) -> int:
	if sdata.decay != StatusData.DECAY_DURATION:
		return existing.remaining
	return _longer_duration(existing.remaining, _resolved_duration(sdata, duration))


# The longer of two durations, where -1 (whole-combat) outranks any finite count.
static func _longer_duration(a: int, b: int) -> int:
	if a == -1 or b == -1:
		return -1
	return maxi(a, b)
