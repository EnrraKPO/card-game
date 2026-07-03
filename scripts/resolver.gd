class_name Resolver
extends RefCounted

# THE single writer of game-state numbers. Anything that wants to change a stat — combat, a
# card effect, a custom hook, a map-event screen — builds a StatMutation and submits it here;
# nothing else in the game mutates these values. Two things this centralisation buys:
#   • Resolution FORM lives here and nowhere else: attack damage routes through shield before
#     health, heals clamp to max, direct wounds bypass shield. Callers say WHAT ("damage 5");
#     the Resolver knows HOW.
#   • Every change flows through one gate, so interception (effects rewriting a mutation
#     before it commits — today done pre-submit for attack damage via EffectContext.pending)
#     can move inside this gate later without touching any call site.
#
# The outcome Dictionary reports what actually happened, for cues/VFX — e.g. a DAMAGE
# mutation returns {"shield_absorbed": int, "health_damage": int}, the split the shield/health
# VFX read. Events are separate from mutations: firing "an attack happened" is the caller's
# (combat's) broadcast, made whether or not any mutation follows.


static func submit(m: StatMutation) -> Dictionary:
	if m == null or m.target == null:
		return {}
	if m.target is DeckCard:
		# Persistent definition bump (the "?" event's permanent +1): the override system's
		# storage writer, gated here so deck edits speak the same contract as live stats.
		(m.target as DeckCard).bump(String(m.stat), m.amount)
		return {"stat": m.stat, "delta": m.amount}
	var inst := m.target as CardInstance
	if inst == null:
		return {}
	match m.stat:
		StatMutation.DAMAGE:
			return _apply_damage(inst, m.amount)
		StatMutation.HEALTH:
			return _apply_health(inst, m.amount)
		StatMutation.SHIELD:
			inst.current_shield = maxi(0, inst.current_shield + m.amount)
			return {"stat": StatMutation.SHIELD, "delta": m.amount}
		_:
			# Additive modifier on any named attribute (attack/speed/cost/max_health/shield/…).
			inst.apply_modifier(String(m.stat), m.amount)
			return {"stat": m.stat, "delta": m.amount}


# ── Set-form conveniences (expressed as additive mutations, so there is still one contract) ──

# Round-start shield refresh: back to the card's base + accumulated shield modifiers.
static func restore_shield(inst: CardInstance) -> void:
	var full: int = inst.data.shield + int(inst.modifiers.get("shield", 0))
	submit(StatMutation.make(inst, StatMutation.SHIELD, full - inst.current_shield,
			null, StatMutation.CH_SYSTEM))


# Fill a fresh unit to its effective max (draw/token setup, once owner + run bonuses are in
# place, so the read-time max_health modifiers are included).
static func fill_health(inst: CardInstance) -> void:
	submit(StatMutation.make(inst, StatMutation.HEALTH,
			inst.get_attribute("max_health") - inst.current_health,
			null, StatMutation.CH_SYSTEM))


# Set current health to an absolute value (king persistence), routed as a signed HEALTH delta.
static func set_health(inst: CardInstance, value: int) -> void:
	submit(StatMutation.make(inst, StatMutation.HEALTH, value - inst.current_health,
			null, StatMutation.CH_SYSTEM))


# ── Application forms (private knowledge of HOW each stat resolves) ──

static func _apply_damage(inst: CardInstance, amount: int) -> Dictionary:
	# An incoming hit: the shield absorbs first, the rest wounds health. Damage never heals —
	# a sub-zero amount deals 0. (Direct health changes — poison, heals — are HEALTH mutations
	# and bypass this entirely.)
	amount = maxi(0, amount)
	var absorbed := 0
	if inst.current_shield > 0:
		absorbed = mini(amount, inst.current_shield)
		inst.current_shield -= absorbed
		amount -= absorbed
	inst.current_health -= amount
	return {"shield_absorbed": absorbed, "health_damage": amount}


static func _apply_health(inst: CardInstance, amount: int) -> Dictionary:
	# Signed direct health change: negative wounds through the shield (poison); positive
	# heals, clamped to effective max. Reports the delta that actually landed.
	if amount < 0:
		inst.current_health += amount
		return {"stat": StatMutation.HEALTH, "delta": amount}
	var healed := mini(amount, inst.get_attribute("max_health") - inst.current_health)
	if healed > 0:
		inst.current_health += healed
	return {"stat": StatMutation.HEALTH, "delta": healed}
