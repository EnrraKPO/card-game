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
# effects fold into get_attribute (MODIFIER) and fire via EffectSystem.trigger (TRIGGERED).
var statuses: Array = []

# Set true for the round when this unit spent its attack to generate a card
# (see rook/building generation in combat.gd). Reset at the start of each round.
var attack_exhausted: bool = false
# Transient: how many of this unit's upcoming attacks deal 0 damage. Each negation source adds one;
# combat consumes one per strike. A bare count — it carries no notion of what queued the negations
# or why; each cause's own cue is separate.
var negate_next_attacks: int = 0
# On a rook-generated token, points back to the building that produced it so
# playing the token can exhaust that building's attack. Null on normal units.
var source_building: CardInstance = null

var is_spell: bool:
	get: return data != null and data.card_type == CardData.CardType.SPELL


static func from_data(card_data: CardData) -> CardInstance:
	var inst := CardInstance.new()
	inst.data = card_data
	inst.current_health = card_data.health
	inst.current_shield = card_data.shield
	return inst


# Returns the effective value of an attribute: base + this instance's accumulated modifiers
# (from triggered effects / charms) + any run-wide CARD modifiers that match this card
# (upgrades/relics, resolved at read-time — see GameData.card_bonus, guarded to player units).
func get_attribute(attr: String) -> int:
	match attr:
		"health":     return current_health
		"max_health": return data.health + modifiers.get("max_health", 0) + GameData.card_bonus(self, "max_health") + StatusEngine.modifier_bonus(self, "max_health")
		"attack":     return data.attack + modifiers.get("attack",     0) + GameData.card_bonus(self, "attack")     + StatusEngine.modifier_bonus(self, "attack")
		"speed":      return data.speed  + modifiers.get("speed",      0) + GameData.card_bonus(self, "speed")      + StatusEngine.modifier_bonus(self, "speed")
		"cost":       return data.cost   + modifiers.get("cost",       0) + GameData.card_bonus(self, "cost")       + StatusEngine.modifier_bonus(self, "cost")
		"shield":     return current_shield
		_:            return modifiers.get(attr, 0)


func apply_modifier(attr: String, delta: int) -> void:
	modifiers[attr] = modifiers.get(attr, 0) + delta


func take_damage(amount: int) -> Dictionary:
	# An incoming hit: the shield absorbs first, the rest wounds health. Damage never heals: a
	# sub-zero attack (units may have <0 Attack) deals 0, not negative. Clamping here keeps the
	# invariant for every damage source, not just attacks. Direct health changes (the "health"
	# attribute — poison, heals) bypass this entirely; see EffectSystem._apply.
	amount = maxi(0, amount)
	var absorbed := 0
	if current_shield > 0:
		absorbed = mini(amount, current_shield)
		current_shield -= absorbed
		amount -= absorbed
	current_health -= amount
	return {"shield_absorbed": absorbed, "health_damage": amount}


func restore_shield() -> void:
	current_shield = data.shield + modifiers.get("shield", 0)


func is_alive() -> bool:
	return current_health > 0


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
