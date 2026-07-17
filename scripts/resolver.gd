class_name Resolver
extends RefCounted

# THE single writer of game-state numbers. Anything that wants to change a stat — combat, a
# card effect, a custom hook, a map-event screen — builds a StatMutation and submits it here;
# nothing else in the game mutates these values. Two things this centralisation buys:
#   • Resolution FORM lives here and nowhere else: attack damage routes through shield before
#     health, heals clamp to max, direct wounds bypass shield. Callers say WHAT ("damage 5");
#     the Resolver knows HOW.
#   • INTERCEPTION happens inside the gate: before a mutation on a CardInstance commits, every
#     active container's INTERCEPTOR effects (the participants' cards + statuses AND the run
#     set — relics/upgrades) get to rewrite its amount, matched declaratively by stat/channel/
#     participant/conditions — e.g. Blind multiplies the holder's outgoing attack damage to 0;
#     a relic adds +1 to every allied heal. No call site knows interception exists; the
#     Outcome records what fired so presentation can cue the right pips/chips afterwards.
#
# Every submit returns an Outcome — the standardized report of what actually happened, and
# the embryo of the future outcome stream presentation will consume. Events stay separate
# from mutations: firing "an attack happened" is the caller's (combat's) broadcast, made
# whether or not any mutation follows.


# What actually happened when a mutation was applied. Uniform shape: `stat` + the signed
# `delta` that LANDED (0 = nothing happened — clamped away, floored, blocked, or a no-op
# submit). The DAMAGE form additionally reports its split (what the shield ate vs what
# wounded health), which the shield/health VFX read separately. `interceptions` lists every
# interceptor that rewrote the mutation, in firing order — presentation-only data
# ({owner_kind, owner_id, holder, delta}) for cueing pips; resolution never reads it back.
class Outcome:
	var target: Object = null
	var stat: StringName = &""
	var delta: int = 0
	var shield_absorbed: int = 0   # DAMAGE form only
	var health_damage: int = 0     # DAMAGE form only
	var interceptions: Array = []

	static func make(p_target: Object, p_stat: StringName, p_delta: int) -> Outcome:
		var o := Outcome.new()
		o.target = p_target
		o.stat = p_stat
		o.delta = p_delta
		return o


static func submit(m: StatMutation) -> Outcome:
	var out := _submit(m)
	# Any committed write may change which standing effects reach whom — drop the settled
	# composition snapshot (Layer 1); the next condition read recomputes lazily. The Resolver
	# being the single stat/status writer is what makes this ONE hook cover them all.
	LiveEffects.invalidate_compositions()
	return out


static func _submit(m: StatMutation) -> Outcome:
	if m == null or m.target == null:
		return Outcome.new()
	if m.target is DeckCard:
		# Persistent definition bump (the "?" event's permanent +1): the override system's
		# storage writer, gated here so deck edits speak the same contract as live stats.
		# Definition edits are out-of-combat bookkeeping — never intercepted.
		(m.target as DeckCard).bump(String(m.stat), m.amount)
		return Outcome.make(m.target, m.stat, m.amount)
	if m.target is CombatSide:
		# Player-resource mutation (draw / discard / mana / max_mana) — intercepted like any
		# live stat: "your draws are doubled" is just an interceptor with intercept "draw".
		var side_interceptions := _intercept(m)
		var sout := _apply_to_side(m.target as CombatSide, m)
		sout.interceptions = side_interceptions
		return sout
	var inst := m.target as CardInstance
	if inst == null:
		return Outcome.new()
	var interceptions := _intercept(m)
	var out := _apply_to_instance(inst, m)
	# The application form may have run nested gates of its own (a DAMAGE split intercepts
	# its shield/health portions — see _apply_damage): keep those records, in firing order.
	out.interceptions = interceptions + out.interceptions
	return out


static func _apply_to_instance(inst: CardInstance, m: StatMutation) -> Outcome:
	# The lethal crossing is stamped HERE, around the stat dispatch, so it covers every form
	# that lowers health — the shield-split DAMAGE and the direct HEALTH (poison) alike. Only
	# the FIRST mutation to take a live unit to <= 0 records the kill (the `pre > 0` guard);
	# overkill from a later mutation can't overwrite the killer. The Resolver only RECORDS the
	# cause — combat emits the event (its contract: events are never mutations).
	var pre_health := inst.current_health
	var out := _dispatch_apply(inst, m)
	if pre_health > 0 and inst.current_health <= 0:
		# An attack credits its striker as the killer unit; every other cause credits none —
		# "died from poison"/"from an effect" is a causeful death with no killer UNIT.
		inst.killed_by_unit = m.source if m.channel == StatMutation.CH_ATTACK else null
		inst.killed_by_channel = m.channel
		inst.killed_by_cause = m.cause
	return out


static func _dispatch_apply(inst: CardInstance, m: StatMutation) -> Outcome:
	match m.stat:
		StatMutation.DAMAGE:
			return _apply_damage(inst, m)
		StatMutation.HEALTH:
			return _apply_health(inst, m.amount)
		StatMutation.STATUS:
			# Status application — the Resolver is the single writer of statuses too, which is
			# what lets interceptors rewrite the stack count. An application intercepted away
			# (amount <= 0) applies nothing and reports delta 0. Stacking/clamping knowledge
			# stays in apply_status; delta reports the REQUESTED stacks (the pre-clamp ask).
			if m.amount <= 0 or m.status_id.is_empty():
				return Outcome.make(inst, StatMutation.STATUS, 0)
			inst.apply_status(m.status_id, m.status_duration, m.amount, m.source)
			return Outcome.make(inst, StatMutation.STATUS, m.amount)
		StatMutation.SHIELD_POOL:
			# Pool floors at 0; the outcome reports the change that ACTUALLY landed. (Plain
			# "shield" is the per-round BASE — an additive modifier, handled below.)
			var prev := inst.current_shield
			inst.current_shield = maxi(0, prev + m.amount)
			return Outcome.make(inst, StatMutation.SHIELD_POOL, inst.current_shield - prev)
		_:
			# Additive modifier on any named attribute (attack/speed/cost/max_health/shield/…).
			inst.apply_modifier(String(m.stat), m.amount)
			return Outcome.make(inst, m.stat, m.amount)


# ── Application forms: CombatSide (player resources) ──
# The side stats' resolution knowledge: draw/discard floor at 0 and stop at their zone's
# supply (delta reports what actually moved); mana floors at 0 and is UNCAPPED above
# max_mana (settled — no clamp); max_mana floors at 0. The side's primitives commit and
# emit; the forms decide how much.

static func _apply_to_side(side: CombatSide, m: StatMutation) -> Outcome:
	match m.stat:
		StatMutation.DRAW:
			var drawn := side.pull_to_hand(maxi(0, m.amount))
			return Outcome.make(side, StatMutation.DRAW, drawn.size())
		StatMutation.DISCARD:
			var gone := side.discard_random(maxi(0, m.amount))
			return Outcome.make(side, StatMutation.DISCARD, gone.size())
		StatMutation.MANA:
			var prev := side.mana
			side.set_mana(maxi(0, prev + m.amount))
			return Outcome.make(side, StatMutation.MANA, side.mana - prev)
		StatMutation.MAX_MANA:
			var prev_max := side.max_mana
			side.set_max_mana(maxi(0, prev_max + m.amount))
			return Outcome.make(side, StatMutation.MAX_MANA, side.max_mana - prev_max)
		_:
			# Load validation keeps authored data out of here; a programmatic mismatch
			# fails loud and commits nothing.
			push_error("Resolver: stat '%s' is not a side stat" % String(m.stat))
			return Outcome.make(side, m.stat, 0)


# ── Set-form conveniences (expressed as additive mutations, so there is still one contract) ──

# Round-start shield refresh: back to the effective base — card stat + baked modifiers +
# live standing effects, i.e. the same max_shield read the pool measures itself against.
static func restore_shield(inst: CardInstance) -> void:
	submit(StatMutation.make(inst, StatMutation.SHIELD_POOL,
			inst.get_attribute("max_shield") - inst.current_shield,
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


# Turn bookkeeping set-forms for a side's mana gauge (the ramp + refill at round start),
# routed as signed system-channel deltas — same pattern as set_health.
static func set_side_max_mana(side: CombatSide, value: int) -> void:
	submit(StatMutation.make(side, StatMutation.MAX_MANA, value - side.max_mana,
			null, StatMutation.CH_SYSTEM))


static func set_side_mana(side: CombatSide, value: int) -> void:
	submit(StatMutation.make(side, StatMutation.MANA, value - side.mana,
			null, StatMutation.CH_SYSTEM))


# ── Application forms (private knowledge of HOW each stat resolves) ──

static func _apply_damage(inst: CardInstance, m: StatMutation) -> Outcome:
	# An incoming hit: the shield absorbs first, the rest wounds health. Damage never heals —
	# a sub-zero amount deals 0. (Direct health changes — poison, heals — are HEALTH mutations
	# and bypass this entirely.)
	#
	# The split happens INSIDE the interception boundary: once the total (`damage`, already
	# gated by submit) is apportioned, each share becomes its own pending mutation on the
	# hit's channel — the shield share as SHIELD_POOL, the health share as HEALTH — and runs
	# the same gate before committing. That is what lets an interceptor speak to "damage
	# that would reach Health" (Stalwart Barrier) or "damage the shield eats", with the
	# channel carrying provenance as everywhere else. No re-flow: a rewritten portion never
	# redistributes to the other. Portions are reductions by construction (see
	# StatMutation.portion); a hit's untouched share commits exactly as split.
	var amount := maxi(0, m.amount)
	var absorbed := mini(amount, inst.current_shield)
	var records: Array = []
	var sm := StatMutation.make(inst, StatMutation.SHIELD_POOL, -absorbed, m.source, m.channel)
	sm.portion = true
	records.append_array(_intercept(sm))
	absorbed = clampi(-sm.amount, 0, inst.current_shield)
	var pierce := amount - mini(amount, inst.current_shield)
	var hm := StatMutation.make(inst, StatMutation.HEALTH, -pierce, m.source, m.channel)
	hm.portion = true
	records.append_array(_intercept(hm))
	pierce = maxi(0, -hm.amount)
	inst.current_shield -= absorbed
	inst.current_health -= pierce
	var o := Outcome.make(inst, StatMutation.DAMAGE, -(absorbed + pierce))
	o.shield_absorbed = absorbed
	o.health_damage = pierce
	o.interceptions = records
	return o


static func _apply_health(inst: CardInstance, amount: int) -> Outcome:
	# Signed direct health change: negative wounds through the shield (poison); positive
	# heals, clamped to effective max. Reports the delta that actually landed.
	if amount < 0:
		inst.current_health += amount
		return Outcome.make(inst, StatMutation.HEALTH, amount)
	var healed := mini(amount, inst.get_attribute("max_health") - inst.current_health)
	if healed > 0:
		inst.current_health += healed
	return Outcome.make(inst, StatMutation.HEALTH, healed)


# ── Interception (see Effect.Kind.INTERCEPTOR) ──
# Before a mutation commits, every active container's interceptors get to rewrite the amount —
# universal interception: the same source set every other evaluator enumerates (a participant
# unit's own card + statuses, and the run set: relics/upgrades via GameData.current_modifiers).
# WHO an interceptor scrutinises is the effect's own data (participant + identity/conditions),
# not the enumeration. Fixed structural order (no authored ordering yet): source unit →
# target unit → run set; within a unit: native effects, then each status's (scaled by stack
# count). Each match rolls its own chance. DAMAGE and STATUS amounts are re-floored at 0
# after every rewrite — a blocked strike is 0, never a heal; an intercepted-away status
# application applies nothing (split-hit portions clamp the mirror way, at <= 0). Runs
# once per pending mutation — a DAMAGE hit passes through up to three times: the total,
# then its shield and health portions (see _apply_damage). Returns the presentation
# records for Outcome.interceptions.

static func _intercept(m: StatMutation) -> Array:
	var records: Array = []
	var t := m.target as CardInstance
	_intercept_unit(m.source, m, records)
	if t != null and t != m.source:
		_intercept_unit(t, m, records)
	if GameData.current_modifiers != null:
		for e: Effect in GameData.current_modifiers.interceptors():
			# Run scope: no holder; owned by the PLAYER side (the allegiance anchor).
			_try_intercept(e, 1, null, 0, m, records, null,
					GameData.current_modifiers.owner_of(e))
	return records


static func _intercept_unit(holder: CardInstance, m: StatMutation, records: Array) -> void:
	if holder == null or holder.data == null:
		return
	# The enumeration knows which container it is iterating — that knowledge stays HERE
	# (dispatch context for the cue record) and in the blind fired() channel; the effects
	# themselves are container-blind.
	for e: Effect in holder.data.effects:
		_try_intercept(e, 1, holder, holder.owner, m, records, null, {})
	for si: StatusInstance in holder.statuses:
		for e: Effect in si.data.effects:
			_try_intercept(e, si.stacks, holder, holder.owner, m, records, si, {})


static func _try_intercept(e: Effect, stacks: int, holder: CardInstance, owner_side: int,
		m: StatMutation, records: Array, si: StatusInstance, run_owner: Dictionary) -> void:
	if e.kind != Effect.Kind.INTERCEPTOR:
		return
	if e.intercept != m.stat:
		return
	if e.channel != &"" and e.channel != m.channel:
		return
	# The participant gate: which side of the pending mutation this interceptor scrutinises.
	# A missing participant (system mutation with no source) never matches. When the target
	# is a CombatSide, THE SIDE is the target participant: allegiance conditions compare its
	# owner against the anchor; identity and the unit-form predicates can never match a side
	# (a player has no stats/composition and is nobody's holder).
	var participant: CardInstance = null
	var side: CombatSide = null
	if e.intercept_participant == "source":
		participant = m.source
	elif m.target is CombatSide:
		side = m.target as CombatSide
	else:
		participant = m.target as CardInstance
	if participant == null and side == null:
		return
	# Structural identity (legacy role / of.relation "self"): the participant must BE the
	# holder — by construction never matched by a holderless (run-scope) container, and
	# never by a side participant.
	if e.intercept_identity and (side != null or participant != holder):
		return
	# Conditions — the shared grammar's fourth socket (trigger → targets → payload →
	# intercept): mutation-form predicates read the pending mutation; unit forms read the
	# selected participant against the owner anchor (allegiance/composition/stat/status);
	# a side participant answers only the allegiance form (fail-closed otherwise).
	for c: EffectCondition in e.conditions:
		if c.is_mutation_form():
			if not c.evaluate_mutation(m):
				return
		elif side != null:
			if not c.evaluate_side(side.owner, owner_side):
				return
		elif not c.evaluate(participant, owner_side):
			return
	if e.chance < 1.0 and randf() >= e.chance:
		return
	var before := m.amount
	if e.op == Effect.Op.MUL:
		m.amount = int(round(m.amount * e.amount))
	else:
		m.amount += e.amount_int() * stacks   # additive rewrites scale by stacks, like stat deltas
	if m.stat == StatMutation.DAMAGE or m.stat == StatMutation.STATUS \
			or m.stat == StatMutation.DRAW or m.stat == StatMutation.DISCARD:
		# Magnitude-form stats re-floor after every rewrite — an intercepted-away draw
		# draws nothing; it never becomes a discard.
		m.amount = maxi(0, m.amount)
	elif m.portion:
		# A split hit's shield/health share is a reduction by construction: re-clamp at 0
		# after every rewrite, so "take less" zeroes a wound but never flips it into a heal.
		m.amount = mini(0, m.amount)
	if m.amount == before:
		# Changed nothing = didn't fire: no cue, no charge spent. This is what makes a Barrier
		# ignore a whiff — blocking a 0-damage strike (a Blinded attacker's miss) is a no-op.
		return
	if run_owner.is_empty():
		records.append({
			"owner_kind": "status" if si != null else "card",
			"owner_id": si.data.id if si != null else str(holder.data.id),
			"holder": holder, "delta": m.amount - before,
		})
	else:
		records.append({
			"owner_kind": str(run_owner.get("kind", "run")),
			"owner_id": str(run_owner.get("id", "")),
			"holder": null, "delta": m.amount - before,
		})
	# The blind upward channel: the container learns one of its effects actually fired and
	# reacts on its own terms — an intercept-decay status (Barrier) spends a charge.
	if si != null:
		si.fired(e)
