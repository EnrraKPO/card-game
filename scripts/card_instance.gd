class_name CardInstance
extends GameEntity

# Fires on every current_health write (damage, healing, shield bleed-through, initial draw/reset).
# Combat connects this for the player King specifically to drive the header's live HP display (see
# [[header-system]]) — RunData.king_damage is only the POST-fight snapshot, so it can't be the
# source of a mid-fight signal; the board unit's live health is.
signal health_changed(current: int)

var data: CardData
var current_health: int : set = _set_current_health

# Shield mirrors the health pair: "max_shield" is the DERIVED base (card stat + baked
# modifiers + live standing effects, recomputed on every read — see get_attribute), and
# what's been absorbed this round is the stored state. The pool is their difference,
# floored at 0 — so a standing bonus appearing mid-round raises the pool immediately, its
# expiry lowers it, and absorbed damage stays absorbed through both (the same coupling
# rule max_health changes use: preserve the damage, move the current with the max).
var shield_spent: int = 0
var current_shield: int:
	get:
		return maxi(0, get_attribute("max_shield") - shield_spent)
	set(v):
		shield_spent = get_attribute("max_shield") - v


func _set_current_health(v: int) -> void:
	current_health = v
	health_changed.emit(v)
# ALLEGIANCE — whose army this unit fights for (0 = player, 1 = enemy). NOT a position.
# Where the unit stands is the board's business and nobody else's: ask the world
# (BoardFacade.location_of), whose LocationManager is the sole container of coordinates.
# A unit is not the authority on its own position — the board moves it. See
# LOCATION_MANAGER_DESIGN.md §2.1/§4.5; the two questions are separate because they can
# disagree, and conflating them is exactly the defect that initiative was written to kill.
var owner: int = -1
var modifiers: Dictionary = {}  # attribute id -> cumulative int delta
# Charm ids attached to this card (display only — their mechanics are already baked into
# `data` by DeckCard.make_instance). Empty for enemies, kings, and tokens.
var charms: Array = []
# (Live Statuses — `statuses` and its lookups — are inherited from GameEntity: a unit is
# one kind of status carrier, with zero say in status behavior. See StatusEngine.)

# Provenance of the FATAL blow — stamped by the Resolver at the lethal HP crossing, read by
# combat to fire the `kill` event before `death` (see GameEvent). `killed_by_unit` is the
# killer UNIT, populated ONLY for an attack (an effect/poison kill credits no unit — that is
# the deliberate rule: units kill by striking). `killed_by_channel` is the cause KIND
# (attack/effect), `killed_by_cause` the specific id (a status id like "poison", else "").
# `killed_by_channel == ""` means "died with no recorded cause" — fires `death` only.
var killed_by_unit: CardInstance = null
var killed_by_channel: StringName = &""
var killed_by_cause: StringName = &""

# Whether this unit's act for the round is SPENT (attacking, or paying an ability's tap
# cost when activation returns — tap ≡ exhausted). Reset at the start of each round.
var attack_exhausted: bool = false

var is_spell: bool:
	get: return data != null and data.card_type == CardData.CardType.SPELL


# The layer this thing occupies when it is on the board — an OPAQUE tag the manager files by
# and never interprets (LOCATION_MANAGER_DESIGN.md §2.3). Units are the pieces layer; the
# ground under them is another. The manager holds no list of layers, so declaring one here is
# the whole of joining it.
func dock_layer() -> StringName:
	return BoardFacade.PIECES


static func from_data(card_data: CardData) -> CardInstance:
	var inst := CardInstance.new()
	inst.data = card_data
	inst.current_health = card_data.health
	# shield_spent starts at 0 — the pool reads as the full effective base (max_shield)
	return inst


# Deep-copy for world snapshots (see CombatWorld.copy). `remap` is the snapshot's identity
# table (original -> copy), shared across the whole copy pass: every unit reference inside
# the copy (killed_by_unit, a status's source/carrier) resolves through it,
# so relationships between copies mirror the originals' exactly — including references to
# units no longer ON the world (a buried killer), which get copied on first encounter.
# Memoized null-safe entry point; the copy registers in the table BEFORE its references are
# filled, so reference cycles (mutual killers) terminate.
#
# Tier rule (COMBAT_DECOUPLING_REFACTOR.md Step 1): mutable per-instance state is duplicated;
# immutable definitions (CardData, AbilityData, StatusData) are shared by reference.
static func copied(inst: CardInstance, remap: Dictionary) -> CardInstance:
	if inst == null:
		return null
	if remap.has(inst):
		return remap[inst]
	var copy := CardInstance.new()
	remap[inst] = copy
	copy.data = inst.data
	copy.current_health = inst.current_health   # emits health_changed — a fresh copy has no subscribers
	copy.shield_spent = inst.shield_spent
	copy.owner = inst.owner
	# Placement is NOT copied here — the world's LocationManager copies it, through this same
	# identity remap, so a copied unit's position comes from the copied board rather than from
	# a field that could drift out of step with it (CombatWorld.copy / LocationManager.copy).
	copy.modifiers = inst.modifiers.duplicate()
	copy.charms = inst.charms.duplicate()
	copy.killed_by_unit = copied(inst.killed_by_unit, remap)
	copy.killed_by_channel = inst.killed_by_channel
	copy.killed_by_cause = inst.killed_by_cause
	copy.attack_exhausted = inst.attack_exhausted
	for si: StatusInstance in inst.statuses:
		copy.statuses.append(StatusInstance.copied(si, copy, remap))
	return copy


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
		"max_shield": return data.shield + modifiers.get("shield", 0) + LiveEffects.bonus(self, "max_shield")
		# Additive dodge-chance bonus in PERCENTAGE POINTS (base 0 — no innate card stat yet).
		# Folds written modifiers + live standing effects like the other stats; read by
		# Resolver.dodge_chance, where it stacks on the speed-derived chance before the cap.
		"dodge_bonus": return modifiers.get("dodge_bonus", 0) + LiveEffects.bonus(self, "dodge_bonus")
		# Crit's two stored axes, same fold shape as dodge_bonus (base 0 — no innate card stat).
		# crit_chance_bonus is percentage points on the chance; crit_multiplier_bonus is
		# multiplier points ×100 (50 = +0.5×). Read by Resolver.crit_chance / crit_multiplier.
		"crit_chance_bonus": return modifiers.get("crit_chance_bonus", 0) + LiveEffects.bonus(self, "crit_chance_bonus")
		"crit_multiplier_bonus": return modifiers.get("crit_multiplier_bonus", 0) + LiveEffects.bonus(self, "crit_multiplier_bonus")
		# Attacks per combat round (combat._resolve_attack loops this many strikes). Base is the
		# card's authored stat (1 for almost everyone); written modifiers and live standing
		# effects fold in like any stat, floored at 1 — a debuff can't strip the basic attack.
		"strikes": return maxi(1, data.strikes + modifiers.get("strikes", 0) + LiveEffects.bonus(self, "strikes"))
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


# Whether at least one of this unit's abilities is currently offerable — the readiness half
# of the one usability rule (AbilityData.ready); mana affordability is checked later, at
# cast time.
func has_available_abilities() -> bool:
	for ab: AbilityData in ability_list():
		if ab.ready(attack_exhausted):
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
	# The data swap changes the BASE composition; reads derive fresh (nothing cached —
	# LiveEffects ruling 2026-08-11), so the health read below sees the new identity.
	Resolver.set_health(self, maxi(1, get_attribute("max_health") - damage))


# (Status application/stacking rules live in StatusEngine.apply — the unit holds the list
# it inherits from GameEntity and nothing else.)
