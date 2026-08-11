class_name Arbitrator
extends RefCounted

# Dodge tuning is DATA-DRIVEN — all four knobs live in res://data/combat_tuning.json (authored
# via the Tool's ⚡ Dodge handle) so balance moves without a code edit. All rates are PERCENTAGES
# of a strike being avoided; the chance is assembled in dodge_chance() as:
#     fixed_pct  +  per_speed_pct × target_speed  +  per_speed_diff_pct × max(0, tgt − atk speed)
# then capped at max_pct (so the fastest units are never untouchable). The speed-difference term
# is ONE-SIDED: it only rewards a target that OUTSPEEDS its attacker; a slower target just loses
# the bonus, never takes a penalty. See DODGE_DEFAULT for the shipped shape / fallbacks.
const DODGE_TUNING_PATH := "res://data/combat_tuning.json"
const DODGE_DEFAULT := {
	"fixed_pct": 0.0,
	"per_speed_pct": 1.0,
	"per_speed_diff_pct": 4.0,
	"max_pct": 75.0,
}
static var _dodge_cfg: Dictionary = {}

# Crit tuning — dodge's offensive sibling, same file, sibling "crit" key. The chance is
# assembled in crit_chance() from the ATTACKER's speed (settled design: Speed is the precision
# stat on both sides of an exchange — the defender's drives dodge, the attacker's drives crit):
#     fixed_pct  +  per_speed_pct × attacker_speed  +  per_speed_diff_pct × max(0, atk − tgt speed)
# capped at max_pct. `multiplier` is the crit damage factor (2.0 = double), raised by the
# attacker's crit_multiplier_bonus (points ×100) and capped at multiplier_max — no relic makes
# a hit infinite. Crit resolves AFTER interception, only on a hit that still deals > 0.
const CRIT_DEFAULT := {
	"fixed_pct": 5.0,
	"per_speed_pct": 1.0,
	"per_speed_diff_pct": 0.0,
	"max_pct": 75.0,
	"multiplier": 2.0,
	"multiplier_max": 5.0,
}
static var _crit_cfg: Dictionary = {}

# Master switches for the dodge/crit rolls. On in the live game; the deterministic regression
# harness turns them OFF so damage-math assertions aren't perturbed by a random avoid or spike
# (each feature's suite flips its own back on around injected tuning). These are the ONLY
# randomness in the Arbitrator that isn't authored per-effect, so they're the only determinism seams.
static var dodge_enabled := true
static var crit_enabled := true

# THE single writer of game-state numbers. Anything that wants to change a stat — combat, a
# card effect, a custom hook, a map-event screen — builds a StatMutation and submits it here;
# nothing else in the game mutates these values. Two things this centralisation buys:
#   • Resolution FORM lives here and nowhere else: attack damage routes through shield before
#     health, heals clamp to max, direct wounds bypass shield. Callers say WHAT ("damage 5");
#     the Arbitrator knows HOW.
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
	# DAMAGE form only: the strike was DODGED — the target avoided an attack outright, so the
	# whole hit was zeroed before it could touch shield or health (see _apply_damage / dodge).
	# Distinct from an ordinary 0-delta whiff: presentation will branch on this to cue a dodge
	# (VFX/SFX/event hooks are a follow-up task).
	var dodged: bool = false
	# DAMAGE form only: the strike was a CRITICAL — the attacker's blow landed harder, and the
	# post-interception amount was multiplied up (see _submit / crit_chance). The seam for
	# presentation (crit VFX/SFX) and the `crit` trigger event, exactly as `dodged` is for dodge.
	# `crit_bonus_damage` is how much EXTRA the crit added beyond the base hit, for cueing.
	var crit: bool = false
	var crit_bonus_damage: int = 0
	var interceptions: Array = []

	static func make(p_target: Object, p_stat: StringName, p_delta: int) -> Outcome:
		var o := Outcome.new()
		o.target = p_target
		o.stat = p_stat
		o.delta = p_delta
		return o


static func submit(m: StatMutation) -> Outcome:
	return _submit(m)


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
	if m.target is GameEntity and not (m.target is CardInstance):
		# A ground-layer (slot) mutation — the fourth target species. Interception runs the
		# same gate first: unit-shaped interceptors degrade silently (their target-participant
		# cast yields null → no match), while source-gated ones ("statuses YOU apply gain a
		# stack") still fire — see _try_intercept.
		var carrier_interceptions := _intercept(m)
		var cout := _apply_to_carrier(m.target as GameEntity, m)
		cout.interceptions = carrier_interceptions
		return cout
	var inst := m.target as CardInstance
	if inst == null:
		return Outcome.new()
	# DODGE is resolved BEFORE any interception: a dodged attack is avoided outright, so nothing
	# about the hit happens — no shield split, and crucially no interceptor is consumed. A barrier
	# is NOT spent on a strike the unit dodged (there was nothing to block), and blind never fires
	# either. Attack-channel damage only; a real incoming hit (raw amount > 0, pre-interception)
	# is the gate. See dodge_chance for the (itself interceptable) rate.
	if m.stat == StatMutation.DAMAGE and m.channel == StatMutation.CH_ATTACK \
			and dodge_enabled and m.amount > 0 \
			and CombatRng.roll(&"rules") < dodge_chance(inst, m.source):
		var od := Outcome.make(inst, StatMutation.DAMAGE, 0)
		od.dodged = true
		return od
	var interceptions := _intercept(m)
	# CRIT is resolved AFTER interception (settled design, the mirror of dodge-before-
	# interception): a crit only ever procs on a hit that still deals damage once the defensive
	# layer has spoken — a Barrier-blocked (or otherwise fully negated) strike is 0 and never
	# rolls, so it raises no crit event/VFX while still consuming the block normally. The
	# multiplier applies to the FINAL resolved amount; the dedicated anti-crit levers are the
	# interceptable crit_chance / crit_multiplier queries themselves (see crit_chance).
	var crit_bonus := 0
	if m.stat == StatMutation.DAMAGE and m.channel == StatMutation.CH_ATTACK \
			and crit_enabled and m.amount > 0 \
			and CombatRng.roll(&"rules") < crit_chance(m.source, inst):
		var boosted := int(round(m.amount * crit_multiplier(m.source)))
		crit_bonus = maxi(0, boosted - m.amount)
		m.amount += crit_bonus
	var out := _apply_to_instance(inst, m)
	if crit_bonus > 0:
		out.crit = true
		out.crit_bonus_damage = crit_bonus
	# The application form may have run nested gates of its own (a DAMAGE split intercepts
	# its shield/health portions — see _apply_damage): keep those records, in firing order.
	out.interceptions = interceptions + out.interceptions
	return out


static func _apply_to_instance(inst: CardInstance, m: StatMutation) -> Outcome:
	# The lethal crossing is stamped HERE, around the stat dispatch, so it covers every form
	# that lowers health — the shield-split DAMAGE and the direct HEALTH (poison) alike. Only
	# the FIRST mutation to take a live unit to <= 0 records the kill (the `pre > 0` guard);
	# overkill from a later mutation can't overwrite the killer. The Arbitrator only RECORDS the
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
			# Status application — the Arbitrator is the single writer of statuses too, which is
			# what lets interceptors rewrite the stack count. An application intercepted away
			# (amount <= 0) applies nothing and reports delta 0. Stacking/clamping knowledge
			# stays in StatusEngine.apply; delta reports the REQUESTED stacks (the pre-clamp ask).
			if m.amount <= 0 or m.status_id.is_empty():
				return Outcome.make(inst, StatMutation.STATUS, 0)
			StatusEngine.apply(inst, m.status_id, m.status_duration, m.amount, m.source)
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


# ── Application form: a bare GameEntity (a board slot) ──
# Slots hold statuses and nothing else in this build — the STATUS form routes to the same
# StatusEngine.apply call the unit arm uses (one application writer); any other stat aimed
# at a slot is an authoring error: fail loud, commit nothing (slots have no stats to move).

static func _apply_to_carrier(carrier: GameEntity, m: StatMutation) -> Outcome:
	if m.stat != StatMutation.STATUS:
		push_error("Arbitrator: stat '%s' cannot land on a board slot (slots hold statuses only)"
				% String(m.stat))
		return Outcome.make(carrier, m.stat, 0)
	if m.amount <= 0 or m.status_id.is_empty():
		return Outcome.make(carrier, StatMutation.STATUS, 0)
	StatusEngine.apply(carrier, m.status_id, m.status_duration, m.amount, m.source)
	return Outcome.make(carrier, StatMutation.STATUS, m.amount)


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
			push_error("Arbitrator: stat '%s' is not a side stat" % String(m.stat))
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
	#
	# DODGE is handled upstream in _submit (before interception, so a dodged hit spends no
	# barrier); by the time a hit reaches here it was NOT dodged and resolves normally.
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


# The target's chance (0..1) to dodge an incoming attack from `attacker`, assembled from the
# data-driven tuning: a fixed base, a per-speed term, a one-sided per-speed-EDGE term that only
# pays out when the target outspeeds its attacker, and the target's own `dodge_bonus` — extra
# percentage points granted by standing effects (a relic's "+25% dodge to air units"), folded
# through get_attribute like every other stat. Speeds/bonus read through get_attribute, so
# buffs/statuses/run bonuses count.
#
# Public read of the assembled tuning shapes (a duplicate, so callers can't mutate the cache) —
# for UI that EXPLAINS the dodge/crit rules to the player rather than resolving a hit (the card
# inspector's stat guide surfaces the coefficients + caps here). The chances themselves stay the
# authoritative dodge_chance/crit_chance below.
static func dodge_tuning() -> Dictionary:
	return _dodge_config().duplicate(true)


static func crit_tuning() -> Dictionary:
	return _crit_config().duplicate(true)


# The assembled rate is then INTERCEPTABLE through the universal gate (stat "dodge", attack
# channel): a relic can triple an air unit's dodge (mul 3) or cancel enemy dodge (mul 0), matched
# by participant (target = the dodger, source = the attacker) + conditions like every other
# interception. It rides as integer percentage points and is rewritten in place — never applied
# to any pool (dodge is a query, not a state write). Finally capped at max_pct (so even a tripled
# rate stays hittable) and floored/ceiled to a valid [0,1] probability. `attacker` may be null (a
# sourceless hit) — then the edge term and the source-side interceptors are simply absent.
static func dodge_chance(target: CardInstance, attacker: CardInstance = null) -> float:
	if target == null:
		return 0.0
	# Buildings are rooted structures — they never dodge, whatever their speed or bonuses. A
	# hard 0 before any tuning/bonus/interception: a relic can't grant a building dodge either.
	if target.data != null and target.data.is_building():
		return 0.0
	var cfg := _dodge_config()
	var spd := float(target.get_attribute("speed"))
	var pct := float(cfg["fixed_pct"]) + float(cfg["per_speed_pct"]) * spd
	if attacker != null:
		var edge := spd - float(attacker.get_attribute("speed"))
		if edge > 0.0:
			pct += float(cfg["per_speed_diff_pct"]) * edge
	pct += float(target.get_attribute("dodge_bonus"))
	# Rewrite-only interception pass (never submitted/applied): source = attacker, target = the
	# would-be dodger, so interceptors gate on either party. Floors at 0 inside _try_intercept.
	var m := StatMutation.make(target, StatMutation.DODGE, maxi(0, int(round(pct))),
			attacker, StatMutation.CH_ATTACK)
	_intercept(m)
	return clampf(minf(float(m.amount), float(cfg["max_pct"])), 0.0, 100.0) / 100.0


# Lazily loads (and caches) the dodge tuning, falling back to DODGE_DEFAULT for the file or any
# missing key so a partial/absent JSON still works (mirrors CardData._offer_config).
static func _dodge_config() -> Dictionary:
	if not _dodge_cfg.is_empty():
		return _dodge_cfg
	_dodge_cfg = DODGE_DEFAULT.duplicate(true)
	if FileAccess.file_exists(DODGE_TUNING_PATH):
		var file := FileAccess.open(DODGE_TUNING_PATH, FileAccess.READ)
		var json := JSON.new()
		if file != null and json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			var dodge: Variant = (json.data as Dictionary).get("dodge")
			if dodge is Dictionary:
				for k: String in DODGE_DEFAULT:
					if (dodge as Dictionary).get(k) != null:
						_dodge_cfg[k] = float((dodge as Dictionary)[k])
		else:
			push_error("Arbitrator: bad combat_tuning.json — using dodge defaults")
	return _dodge_cfg


# Injects dodge tuning directly, bypassing the JSON (the regression harness uses this to make
# the roll deterministic — 100%/0% chances — and to exercise the formula in isolation). Unset
# keys keep their DODGE_DEFAULT value. Pass {} to force a reload from disk on the next read.
static func set_dodge_tuning(cfg: Dictionary) -> void:
	if cfg.is_empty():
		_dodge_cfg = {}
		return
	_dodge_cfg = DODGE_DEFAULT.duplicate(true)
	for k: String in DODGE_DEFAULT:
		if cfg.get(k) != null:
			_dodge_cfg[k] = float(cfg[k])


# The ATTACKER's chance (0..1) to land a critical hit on `target`, assembled from the data-driven
# tuning: a fixed base, a per-speed term on the ATTACKER's speed, a one-sided per-speed-EDGE term
# that only pays out when the attacker outspeeds its target, and the attacker's own
# `crit_chance_bonus` — extra percentage points granted by standing effects, folded through
# get_attribute like every other stat.
#
# PARTICIPANT ROLES ARE SWAPPED relative to dodge_chance — read carefully before copying either
# pattern onto the other. The transient mutation's `target` is the ATTACKER (the unit whose crit
# chance this is — `target` always means "whoever the queried quantity belongs to") and its
# `source` is the DEFENDER being struck. An interceptor's participant "target" therefore means
# "the unit landing the crit", NOT the unit being hit: "your fire units 3x crit" gates
# participant target/relation ally; "enemies never crit" gates participant target/relation enemy.
# Capped at max_pct. `target` may be null (a targetless query) — then the edge term and the
# defender-side interceptors are simply absent. No building exclusion in either direction
# (settled design): a rook can land a crit and can be crit against.
static func crit_chance(attacker: CardInstance, target: CardInstance = null) -> float:
	if attacker == null:
		return 0.0
	var cfg := _crit_config()
	var spd := float(attacker.get_attribute("speed"))
	var pct := float(cfg["fixed_pct"]) + float(cfg["per_speed_pct"]) * spd
	if target != null:
		var edge := spd - float(target.get_attribute("speed"))
		if edge > 0.0:
			pct += float(cfg["per_speed_diff_pct"]) * edge
	pct += float(attacker.get_attribute("crit_chance_bonus"))
	# Rewrite-only interception pass (never submitted/applied): target = the would-be critter,
	# source = the defender, so interceptors gate on either party. Floors at 0 in _try_intercept.
	var m := StatMutation.make(attacker, StatMutation.CRIT, maxi(0, int(round(pct))),
			target, StatMutation.CH_ATTACK)
	_intercept(m)
	return clampf(minf(float(m.amount), float(cfg["max_pct"])), 0.0, 100.0) / 100.0


# The ATTACKER's crit damage multiplier (e.g. 2.0 = a crit doubles the hit): tuning base +
# the attacker's crit_multiplier_bonus (points ×100 — a +50 bonus on a 2.0 base is 2.5×), then
# interceptable as its own query (stat "crit_multiplier", riding as integer points ×100 on the
# same participant wiring as crit_chance), finally capped at multiplier_max and floored at 1.0
# (a "crit" can never deal LESS than the base hit — intercept crit_chance to deny crits instead).
static func crit_multiplier(attacker: CardInstance, target: CardInstance = null) -> float:
	var cfg := _crit_config()
	if attacker == null:
		return float(cfg["multiplier"])
	var pts := float(cfg["multiplier"]) * 100.0 + float(attacker.get_attribute("crit_multiplier_bonus"))
	var m := StatMutation.make(attacker, StatMutation.CRIT_MULT, maxi(0, int(round(pts))),
			target, StatMutation.CH_ATTACK)
	_intercept(m)
	return clampf(float(m.amount) / 100.0, 1.0, float(cfg["multiplier_max"]))


# Lazily loads (and caches) the crit tuning from the shared combat_tuning.json ("crit" key),
# falling back to CRIT_DEFAULT for the file or any missing key — mirrors _dodge_config.
static func _crit_config() -> Dictionary:
	if not _crit_cfg.is_empty():
		return _crit_cfg
	_crit_cfg = CRIT_DEFAULT.duplicate(true)
	if FileAccess.file_exists(DODGE_TUNING_PATH):
		var file := FileAccess.open(DODGE_TUNING_PATH, FileAccess.READ)
		var json := JSON.new()
		if file != null and json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			var crit: Variant = (json.data as Dictionary).get("crit")
			if crit is Dictionary:
				for k: String in CRIT_DEFAULT:
					if (crit as Dictionary).get(k) != null:
						_crit_cfg[k] = float((crit as Dictionary)[k])
		else:
			push_error("Arbitrator: bad combat_tuning.json — using crit defaults")
	return _crit_cfg


# Injects crit tuning directly, bypassing the JSON — the harness's determinism seam, mirroring
# set_dodge_tuning. Unset keys keep their CRIT_DEFAULT value. Pass {} to force a disk reload.
static func set_crit_tuning(cfg: Dictionary) -> void:
	if cfg.is_empty():
		_crit_cfg = {}
		return
	_crit_cfg = CRIT_DEFAULT.duplicate(true)
	for k: String in CRIT_DEFAULT:
		if cfg.get(k) != null:
			_crit_cfg[k] = float(cfg[k])


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


# ── Interception — THE SEAM (TARGETING_DESIGN.md §8) ──
# Before a mutation commits, this is where InterceptorEffects rewrite the pending amount.
# ENGINE RAZED (2026-08-11): the old union-Effect interceptor walk was deleted with the
# effect layer; nothing authored exists to fire. The pipeline point stays so every commit
# and every rate query keeps passing through the one gate. NEEDS, from the razed engine +
# §8: rewrite-in-chain (each matching interceptor fires in order on the prior result —
# the ORDER itself is an open design ruling; the old code's structural order was never
# sanctioned); magnitude stats re-floor at 0 after EVERY rewrite and split-hit portions
# re-clamp at <= 0; "changed nothing = didn't fire" (no cue, no Barrier charge — the blind
# si.fired() channel is how an intercept-decay status spends itself); enumeration spans
# the participants' containers AND the run set, with owner attribution in the returned
# presentation records ({owner_kind, owner_id, holder, delta}).

static func _intercept(_m: StatMutation) -> Array:
	return []
