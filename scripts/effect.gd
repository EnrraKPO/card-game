class_name Effect
extends RefCounted

# The single effect payload any game component can hold (cards, charms, upgrades, relics,
# heroes). One authored schema, four KINDS routed to the right evaluator:
#   • MODIFIER    — a passive delta on a value. scope=GLOBAL keys a registry number (see
#                   GameAttributes), resolved by GameData.value; scope=CARD keys a card
#                   attribute, folded into CardInstance.get_attribute at read-time for matching
#                   player cards (predicate selection via `filter`).
#   • TRIGGERED   — an event-driven, targeted, conditional effect (the classic card effect).
#                   Dispatched from a card on the board (EffectSystem.trigger) AND at run level
#                   from any active source (EffectSystem.trigger_global).
#   • CUSTOM      — a code hook (EffectHooks) keyed by `custom_id`, for logic the schema can't
#                   express. Fired like a TRIGGERED effect; runs arbitrary code with the context.
#   • INTERCEPTOR — a standing rewrite of a pending StatMutation passing through the Resolver.
#                   NOT an event in time: it matches mutations by stat/channel/role and adjusts
#                   the amount BEFORE it commits (e.g. Blind: my outgoing attack damage ×0, half
#                   the time). Evaluated only inside Resolver.submit — never by the trigger
#                   dispatch. See Resolver._intercept.
# (Activated ABILITIES are not an effect kind: an ability is a definition holding ordinary
# effects behind a COST — see AbilityData. Containers reference abilities by id.)
# `from_dict` is the one parser; it infers the kind from the fields present, so existing card /
# charm / upgrade data loads unchanged.

enum Kind  { MODIFIER, TRIGGERED, CUSTOM, INTERCEPTOR }
enum Scope { GLOBAL, CARD }
enum Op    { ADD, MUL }   # MUL consumed by INTERCEPTOR rewrites (see Resolver._intercept); MODIFIERs are ADD-only today

# INTERCEPTOR: which side of the mutation the HOLDER must be for this to fire — the unit that
# caused it (SOURCE, e.g. Blind on the attacker) or the unit receiving it (TARGET, e.g. armor).
enum Role { SOURCE, TARGET }

enum Trigger {
	ON_PLAY,
	ON_DEATH,
	ON_ATTACK,
	ON_DAMAGE_TAKEN,
	PERMANENT,
	ON_TURN_START,   # fired for every unit at the start of a combat round (status lifecycle)
	ON_TURN_END,     # fired for every unit at the end of a combat round; statuses then count down
	ON_ACTIVATE,     # fired for a unit when ITS turn comes up in the speed-ordered combat loop
}

# Sentinel for "apply this status for its own default duration" (the applier didn't override it).
const STATUS_DURATION_DEFAULT := -9999

enum TargetingPolicy {
	SELF,
	SINGLE_NEAREST,
	SINGLE_RANDOM,
	ALL_ENEMIES,
	ALL_ALLIES,
	ALL,
	MANUAL,
	ATTACK_TARGET,   # the unit this card is currently striking (valid in an ON_ATTACK context)
	SUBJECT,         # the unit the event is about (the activator/actor — see EffectContext.subject)
	ATTACKER,        # the unit that dealt the blow (valid in an ON_DAMAGE_TAKEN context)
	MANUAL_SLOT,     # a SLOT the player picks on their own side — may be EMPTY (the effect decides
	                 # what an empty pick means, e.g. material delivery spawns there); an occupied
	                 # pick is gated by the effect's conditions. See SpellCaster's slot-mode flow.
}

# For an event-driven (TRIGGERED/CUSTOM) effect, which unit — relative to the effect's HOLDER — must
# be the event's subject for the effect to react. Default SELF means "I react only to my own action,"
# which reproduces pre-broadcast behaviour with no data migration. See EffectSystem._subject_matches.
enum SubjectFilter { SELF, ALLY, ENEMY, ANY }

# Card-scoped MODIFIER keys → the CardInstance attribute each one adjusts.
const CARD_ATTR := {
	"unit.attack":      "attack",
	"unit.health":      "max_health",
	"unit.speed":       "speed",
	"unit.dodge_bonus": "dodge_bonus",
	"unit.crit_chance_bonus":     "crit_chance_bonus",
	"unit.crit_multiplier_bonus": "crit_multiplier_bonus",
	"card.cost":        "cost",
}

var kind: Kind = Kind.TRIGGERED   # default keeps all existing (triggered) card/charm data valid

# Shared magnitude. Float so fractional keys (e.g. reward.king_piece_chance) work; the
# triggered/attribute path int()s it.
var amount: float = 0.0

# ── TRIGGERED / CUSTOM fields ──
# THE activation gate: an injected TriggerResolver decides whether this effect fires for a
# given GameEvent (see scripts/triggers/). Authoritative for all dispatch. Built by
# from_dict from either the native form ("trigger" as a dictionary) or the legacy schema
# (trigger string + subject + subject_elements), which maps losslessly — zero migration.
var resolver: TriggerResolver = null
# Whether the trigger was authored in the native (dictionary) form — steers to_dict so both
# schemas round-trip byte-faithfully (legacy in → legacy out).
var authored_native_trigger := false
# THE targeting socket: an injected TargetResolver returns the unit(s) this effect
# affects, from the same shared context the trigger saw (event, holder, board). Built by
# from_dict from either the native form ("targets" as a dictionary) or the legacy
# "targeting_policy" string — zero migration.
var target_resolver: TargetResolver = null
var authored_native_targets := false
var _native_targets: Dictionary = {}   # raw native "targets" form; resolver built lazily
# Legacy/compat mirrors, kept for the consumers that classify effects WITHOUT resolving:
# the spell/ability "== ON_PLAY" include filter, SpellCaster's manual/slot mode checks and
# eligibility reads (conditions), enemy-AI heuristics. Derived for native-form effects;
# never consulted by dispatch.
var trigger: Trigger = Trigger.ON_PLAY
var subject_filter: SubjectFilter = SubjectFilter.SELF
var subject_elements: Array = []   # legacy companion of `trigger`; folded into the resolver
var targeting_policy: TargetingPolicy = TargetingPolicy.SELF
var conditions: Array = []   # Array[EffectCondition]
var attribute: String = ""
var custom_id: String = ""           # CUSTOM: id into EffectHooks
var custom_apply: Callable           # programmatic inline hook (not data-authored)
# CUSTOM (deliver_material): a per-EFFECT material key that overrides the ability's own
# `material`. Empty = fall back to ctx.ability.material. Lets one ability deliver several
# DIFFERENT materials from separate effects (e.g. deliver a pawn, then an element).
var material: String = ""

# Generic "apply a status" payload: any TRIGGERED effect may grant a status to each resolved
# target (in place of / as well as a stat delta). Empty status_id = this effect applies no status.
var status_id: String = ""
var status_duration: int = STATUS_DURATION_DEFAULT   # sentinel = use the status's own default
var status_stacks: int = 1

# Generic "spawn units" payload: any TRIGGERED effect may conjure new units onto the board.
# For each resolved TARGET, `spawn_count` copies of card `spawn_id` are queued on that target's
# SIDE, anchored at its slot — the board flushes the queue after its death sweep, so an on-death
# split reclaims the corpse's own slot (see CombatBoard.queue_spawn). This one payload powers
# splits, broodmother summons, reinforcements, and phase-change bosses (a dying king spawning
# its next form keeps the fight alive — any_king_dead scans the live board). Empty = none.
var spawn_id: String = ""
var spawn_count: int = 1

# ── MODIFIER fields (legacy authored form; card-scoped ones parse into STANDING effects) ──
var scope: Scope = Scope.GLOBAL
var key: String = ""

# ── STANDING ("while"-trigger) fields ──
# The authored tracker spec — the effect's lifetime authority, bound to a host object at
# go-live by EffectTracker.bind (see EffectTracker). Empty = the container-existence default.
var tracker_spec: Dictionary = {}
# Composition GRANT payload: while live, each resolved target COUNTS AS containing these
# component ids for condition resolution — Layer 1 of the layered standing evaluation (see
# LiveEffects.effective_composition). Union-only; the card's real composition (CardData,
# shared identity) is never touched. Exclusive with the attribute/status payloads.
var grants: Array[String] = []

# ── INTERCEPTOR fields ──
var intercept: StringName = &""   # the StatMutation stat this rewrites (e.g. "damage")
var channel: StringName = &""     # provenance filter (e.g. "attack"); empty = any channel
# The relational match gate (native "of" form): which mutation PARTICIPANT this interceptor
# scrutinises ("source"/"target") and whether that participant must BE the holder (identity —
# structural, never a condition, per the stage-2 ruling). Ally/enemy gating is spelled as an
# allegiance CONDITION (the shared grammar; of.relation ally/enemy parses into one). Legacy
# `role` maps losslessly: role source ≡ participant "source" + identity. `role` survives as
# the legacy mirror for byte-faithful round-trips.
var intercept_participant: String = "source"
var intercept_identity := false
var authored_native_intercept := false
var role: Role = Role.SOURCE      # legacy mirror: which side of the mutation the holder must be

# (No owner_kind/owner_id here: an effect NEVER knows what container holds it. Container
# identity travels as dispatch context — the enumeration knows which container it is
# iterating — and reactions to an effect firing go through the container's blind upward
# channel, fired(e). See StatusInstance.fired and EFFECT_SYSTEM_DESIGN.md §2.2.)
# Probabilistic gate, rolled once before the effect resolves: the effect fires with this chance
# (1.0 = always). A declarative condition, separate from what the effect does. See EffectSystem.
var chance: float = 1.0
var op: Op = Op.ADD
var filter: Dictionary = {}   # card selection predicate for scope=CARD


# The one canonical parser. Kind is explicit ("kind") or inferred: a "key" → MODIFIER, a
# "custom" → CUSTOM, otherwise TRIGGERED — so legacy data needs no migration.
static func from_dict(d: Dictionary) -> Effect:
	var e := Effect.new()
	e.amount = float(d.get("amount", 0))
	e.chance = float(d.get("chance", 1.0))
	for c_data: Dictionary in d.get("conditions", []):
		if EffectCondition.is_identity_dict(c_data):
			continue   # {"relation": "self"} is structural (self targeting), not a predicate
		e.conditions.append(EffectCondition.from_dict(c_data))
	var kind_str := str(d.get("kind", ""))
	if kind_str == "modifier" or (kind_str.is_empty() and d.has("key")):
		e.kind = Kind.MODIFIER
		e.key  = d.get("key", "")
		e.op   = Op.MUL if str(d.get("op", "add")) == "mul" else Op.ADD
		var f: Dictionary = d.get("filter", {})
		e.filter = f.duplicate()
		# Scope is inferred from the key (card attribute vs registry number); explicit wins.
		e.scope = Scope.CARD if CARD_ATTR.has(e.key) else Scope.GLOBAL
		if d.has("scope"):
			e.scope = Scope.CARD if str(d.get("scope")) == "card" else Scope.GLOBAL
		# Legacy shim: a card-scoped modifier IS a standing effect — wire it onto the
		# unified path (While resolver + triggered-vocabulary attribute). GLOBAL-scope
		# modifiers stay on the registry path (GameData.value) untouched. The MODIFIER
		# kind + key/filter fields survive purely so to_dict round-trips byte-faithfully.
		# Scope: legacy modifiers always meant "everyone my conditions admit", never the
		# holder alone — an ALL target (identity self, if authored, is stripped as vacuous:
		# on the status path the carrier is the whole candidate set anyway).
		if e.scope == Scope.CARD:
			e.resolver = TriggerResolver.While.new()
			e.trigger = Trigger.PERMANENT
			e.targeting_policy = TargetingPolicy.ALL
			e.attribute = CARD_ATTR.get(e.key, "")
			e.tracker_spec = (d.get("tracker", {}) as Dictionary).duplicate()
	elif kind_str == "interceptor" or (kind_str.is_empty() and d.has("intercept")):
		e.kind      = Kind.INTERCEPTOR
		e.intercept = StringName(str(d.get("intercept", "")))
		e.channel   = StringName(str(d.get("channel", "")))
		e.op        = Op.MUL if str(d.get("op", "add")) == "mul" else Op.ADD
		e._parse_intercept_gate(d)
	elif kind_str == "custom" or (kind_str.is_empty() and d.has("custom")):
		e.kind             = Kind.CUSTOM
		e.custom_id        = d.get("custom", "")
		e.material         = str(d.get("material", ""))
		e._parse_trigger(d)
		e._parse_targets(d)
	else:
		e.kind             = Kind.TRIGGERED
		e._parse_trigger(d)
		e._parse_targets(d)
		e.attribute        = d.get("attribute", "")
		e.tracker_spec     = (d.get("tracker", {}) as Dictionary).duplicate()
		# Parsed for round-trip fidelity; no TRIGGERED evaluator consumes MUL today (the
		# INTERCEPTOR kind is where mul does its work — see Resolver._intercept).
		e.op               = Op.MUL if str(d.get("op", "add")) == "mul" else Op.ADD
	# Optional "apply a status" payload, valid on any event-driven (TRIGGERED) effect.
	var st: Dictionary = d.get("status", {})
	if not st.is_empty():
		e.status_id       = str(st.get("id", ""))
		e.status_duration = int(st.get("duration", STATUS_DURATION_DEFAULT))
		e.status_stacks   = int(st.get("stacks", 1))
	# Optional "spawn units" payload, valid on any event-driven (TRIGGERED) effect.
	var sp: Dictionary = d.get("spawn", {})
	if not sp.is_empty():
		e.spawn_id    = str(sp.get("id", ""))
		e.spawn_count = maxi(1, int(sp.get("count", 1)))
	# Optional composition-grant payload — parsed for every kind so a misplaced "grants"
	# key is caught by _validate_grants (fail loud) instead of silently ignored.
	for g_v: Variant in (d.get("grants", []) as Array):
		e.grants.append(str(g_v))
	e._validate_standing(d)
	e._validate_grants(d)
	e._validate_side_targets(d)
	# Mutation-form conditions predicate over a pending StatMutation — only the interceptor
	# match ever evaluates them. Anywhere else they'd be a silently-vacuous gate: fail loud.
	if e.kind != Kind.INTERCEPTOR:
		for c: EffectCondition in e.conditions:
			if c.is_mutation_form():
				push_error("Effect: mutation-form condition on a non-interceptor effect — %s" % [d])
	return e


# Parses the interceptor match gate from either schema. Native form: "of" is a dictionary
# {"participant": "source"/"target", "relation": "self"/"ally"/"enemy"/"any"} — identity
# (self) is structural; ally/enemy converge onto an allegiance CONDITION prepended to the
# list (one grammar, one canonical spelling). Legacy form: the "role" string, meaning "the
# holder must be that participant" — maps losslessly to participant + identity.
func _parse_intercept_gate(d: Dictionary) -> void:
	var of_v: Variant = d.get("of", null)
	if of_v is Dictionary:
		authored_native_intercept = true
		var of := of_v as Dictionary
		intercept_participant = str(of.get("participant", "target"))
		if not intercept_participant in ["source", "target"]:
			push_error("Effect: unknown intercept participant '%s' — %s" % [intercept_participant, d])
			intercept_participant = "target"
		match str(of.get("relation", "any")):
			"self":
				intercept_identity = true
			"ally", "enemy":
				conditions.push_front(EffectCondition.from_dict({"allegiance": str(of.get("relation"))}))
			"any":
				pass
			_:
				push_error("Effect: unknown intercept relation '%s' — %s" % [str(of.get("relation")), d])
		# Legacy mirror, derived for consumers that classify without matching.
		role = Role.SOURCE if intercept_participant == "source" else Role.TARGET
		return
	role = _str_role(str(d.get("role", "source")))
	intercept_participant = "source" if role == Role.SOURCE else "target"
	intercept_identity = true


# Load-time authoring validation for standing effects — FAIL LOUD, never silently closed
# (a silently-rejected correct condition is the failure mode this redesign exists to kill).
func _validate_standing(d: Dictionary) -> void:
	if not is_standing():
		return
	# Membership, not mere presence: an attribute outside the folded set would be computed
	# by LiveEffects and read by nobody — the silent-evaporation bug this guard exists for
	# (found the hard way: a standing "shield" bonus before max_shield joined the fold).
	# A composition grant carries no attribute — its payload is the grants set instead.
	if grants.is_empty() and not standing_attribute() in FOLDABLE_ATTRS:
		push_error("Effect: standing (while) attribute '%s' is not foldable (%s) — %s"
				% [standing_attribute(), ", ".join(FOLDABLE_ATTRS), d])
	if not status_id.is_empty():
		push_error("Effect: a standing (while) effect cannot apply a status — %s" % [d])
	if not spawn_id.is_empty():
		push_error("Effect: a standing (while) effect cannot spawn units — %s" % [d])
	if kind == Kind.CUSTOM:
		push_error("Effect: a custom hook cannot be standing (while) — %s" % [d])
	# Standing membership is self or condition-based; selection policies (nearest/random/
	# manual) have no meaning for a continuous fold.
	if authored_native_targets and not str(_native_targets.get("kind", "all")) in ["all", "self"]:
		push_error("Effect: standing (while) targets must be the 'self' or 'all' form — %s" % [d])


# Load-time authoring validation for composition grants — FAIL LOUD, same house rule.
# The Layer-1 fixed point (LiveEffects.effective_composition) is provably convergent only
# while grants stay MONOTONE (union-only): a negative composition predicate on a grant
# could un-grant another grant, and the iteration would have no defined answer — so the
# monotonicity contract is enforced here, at load, not "resolved" arbitrarily at runtime.
func _validate_grants(d: Dictionary) -> void:
	if grants.is_empty():
		return
	if not is_standing():
		push_error("Effect: 'grants' requires a standing (while) effect — %s" % [d])
	if not attribute.is_empty() or not status_id.is_empty():
		push_error("Effect: 'grants' is exclusive with the attribute/status payloads — %s" % [d])
	for g: String in grants:
		if not CardData.is_component_id(g):
			push_error("Effect: unknown component id '%s' in grants (%s / %s) — %s"
					% [g, ", ".join(CardData.ELEMENT_IDS), ", ".join(CardData.CHESS_PIECE_IDS), d])
	for c: EffectCondition in conditions:
		if (not c.composition.is_empty() and not c.present) \
				or (c.has_element_set and not c.has_element):
			push_error("Effect: a composition grant cannot carry a negative composition predicate "
					+ "(Layer-1 monotonicity — grants only ever ADD) — %s" % [d])


# Load-time cross-validation of the side-targeted vocabulary — FAIL LOUD both ways:
# a side stat (draw/discard/mana/max_mana) is meaningless on a unit, and a side target
# can commit nothing else (players have no unit stats, no statuses, no conditions to pass).
func _validate_side_targets(d: Dictionary) -> void:
	var side_targeted := authored_native_targets and str(_native_targets.get("kind", "")) == "side"
	if StatMutation.is_side_stat(attribute) and not side_targeted:
		push_error("Effect: side stat '%s' requires targets {\"kind\": \"side\"} — %s" % [attribute, d])
	if not side_targeted:
		return
	if kind != Kind.TRIGGERED:
		push_error("Effect: side targeting is only valid on a triggered effect — %s" % [d])
	if not StatMutation.is_side_stat(attribute):
		push_error("Effect: side-targeted attribute '%s' is not a side stat %s — %s"
				% [attribute, StatMutation.SIDE_STATS, d])
	if not status_id.is_empty():
		push_error("Effect: a side-targeted effect cannot apply a status — %s" % [d])
	if not spawn_id.is_empty():
		push_error("Effect: a side-targeted effect cannot spawn units — %s" % [d])
	if not (_native_targets.get("conditions", []) as Array).is_empty():
		push_error("Effect: side targets take no conditions (players have nothing to predicate on) — %s" % [d])


# Parses the activation gate from either schema. Native form: "trigger" is a Dictionary
# (see TriggerResolver); the legacy compat fields are derived from it. Legacy form: the
# trigger string + subject + subject_elements keys, folded into an equivalent resolver.
func _parse_trigger(d: Dictionary) -> void:
	var trig_v: Variant = d.get("trigger", "on_play")
	if trig_v is Dictionary:
		authored_native_trigger = true
		resolver = TriggerResolver.parse(trig_v, "", [])
		trigger = _derived_legacy_trigger()
		return
	trigger          = _str_trigger(str(trig_v) if not str(trig_v).is_empty() else "on_play")
	subject_filter   = _str_subject(d.get("subject", ""))
	subject_elements = (d.get("subject_elements", []) as Array).duplicate()
	resolver = TriggerResolver.from_legacy(trigger_key(trigger), subject_key(subject_filter), subject_elements)


func _derived_legacy_trigger() -> Trigger:
	if resolver is TriggerResolver.Simple:
		return TriggerResolver.legacy_trigger_for((resolver as TriggerResolver.Simple).event)
	if resolver is TriggerResolver.Dual:
		return TriggerResolver.legacy_trigger_for((resolver as TriggerResolver.Dual).event)
	if resolver is TriggerResolver.While:
		return Trigger.PERMANENT   # standing: excluded from every use-path/apply filter
	return Trigger.ON_PLAY   # transient behaves like on_play for the use-path filters


# The serialized "trigger" value: the native dictionary form when authored that way, the
# legacy string otherwise (kept out of the dict literals — the branches have no shared type).
func _trigger_out() -> Variant:
	if authored_native_trigger:
		return trigger_resolver().to_dict()
	return trigger_key(trigger)


# The activation resolver, lazily derived for programmatically-built effects (Effect.new()
# + field assignment, e.g. in tests) that never went through from_dict.
func trigger_resolver() -> TriggerResolver:
	if resolver == null:
		resolver = TriggerResolver.from_legacy(trigger_key(trigger), subject_key(subject_filter), subject_elements)
	return resolver


# Parses the targeting socket from either schema — WITHOUT constructing the resolver.
# Construction is deferred to targets_resolver(): data files parse during other classes'
# @static_initializer runs, when TargetResolver's script (whose signatures reach into the
# UI layer via EffectContext) may not be compiled yet. Only the raw form and the compat
# mirrors (targeting_policy enum + conditions list) are captured here.
func _parse_targets(d: Dictionary) -> void:
	var tv: Variant = d.get("targets", null)
	if tv is Dictionary:
		authored_native_targets = true
		_native_targets = (tv as Dictionary).duplicate(true)
		conditions = TriggerResolver._parse_conditions(_native_targets.get("conditions", []))
		targeting_policy = _policy_from_native(_native_targets)
		return
	targeting_policy = _str_policy(d.get("targeting_policy", ""))


# The targeting resolver, built on first use (runtime — never during static init).
func targets_resolver() -> TargetResolver:
	if target_resolver == null:
		if authored_native_targets:
			target_resolver = TargetResolver.parse(_native_targets)
			# the mirror and the resolver must share ONE condition list (see TargetResolver)
			target_resolver.conditions = conditions
		else:
			target_resolver = TargetResolver.from_legacy(policy_key(targeting_policy), conditions,
					trigger == Trigger.ON_DAMAGE_TAKEN)
	return target_resolver


# The compat TargetingPolicy for a native "targets" dict — derived from the raw strings so
# no TargetResolver construction is needed at parse time.
static func _policy_from_native(d: Dictionary) -> TargetingPolicy:
	match str(d.get("kind", "all")):
		"self":        return TargetingPolicy.SELF
		"manual":      return TargetingPolicy.MANUAL
		"manual_slot": return TargetingPolicy.MANUAL_SLOT
		# A side target needs no pick and no unit scan — ALL is the honest compat mirror
		# (the classifiers only ask "is this manual / slot-mode?", to which the answer is no).
		"side":        return TargetingPolicy.ALL
		"auto":
			return TargetingPolicy.SINGLE_RANDOM if str(d.get("criterion", "nearest")) == "random" \
					else TargetingPolicy.SINGLE_NEAREST
		"participant":
			match str(d.get("participant", "holder")):
				"origin":      return TargetingPolicy.ATTACKER
				"destination": return TargetingPolicy.ATTACK_TARGET
				_:             return TargetingPolicy.SELF
	# Pre-gate native data spelled self-targeting as all + {"relation": "self"} — that
	# identity entry is structural (the self kind), not a condition.
	if TriggerResolver._has_identity(d.get("conditions", [])):
		return TargetingPolicy.SELF
	return TargetingPolicy.ALL


# Serialises back to the authored shape. Exercised for persisted (overridden) CARD effects,
# which are TRIGGERED — so that path matches the legacy dict exactly.
func to_dict() -> Dictionary:
	match kind:
		Kind.MODIFIER:
			var d := {"kind": "modifier", "key": key, "amount": amount}
			if op == Op.MUL:
				d["op"] = "mul"
			if not filter.is_empty():
				d["filter"] = filter
			if not conditions.is_empty():
				var mconds: Array = []
				for c: EffectCondition in conditions:
					mconds.append(c.to_dict())
				d["conditions"] = mconds
			return d
		Kind.CUSTOM:
			var cd := {
				"kind":    "custom",
				"custom":  custom_id,
				"trigger": _trigger_out(),
			}
			if not material.is_empty():
				cd["material"] = material
			if authored_native_targets:
				cd["targets"] = targets_resolver().to_dict()
			else:
				cd["targeting_policy"] = policy_key(targeting_policy)
			if not authored_native_trigger and subject_filter != SubjectFilter.SELF:
				cd["subject"] = subject_key(subject_filter)
			return cd
		Kind.INTERCEPTOR:
			var idd := {"intercept": String(intercept)}
			if not authored_native_intercept:
				idd["role"] = role_key(role)   # legacy key order preserved: intercept, role, amount
			idd["amount"] = amount
			if authored_native_intercept:
				# Native out: identity keeps its structural spelling; ally/enemy live in the
				# conditions list (the canonical convergence — of.relation in, condition out).
				var of := {"participant": intercept_participant}
				if intercept_identity:
					of["relation"] = "self"
				idd["of"] = of
				if not conditions.is_empty():
					var iconds: Array = []
					for c: EffectCondition in conditions:
						iconds.append(c.to_dict())
					idd["conditions"] = iconds
			if channel != &"":
				idd["channel"] = String(channel)
			if op == Op.MUL:
				idd["op"] = "mul"
			if chance != 1.0:
				idd["chance"] = chance
			return idd
		_:
			var d := {"trigger": _trigger_out()}
			if grants.is_empty():
				d["attribute"] = attribute
				d["amount"]    = amount_int()
			else:
				# A grant's payload IS the component set — no attribute/amount keys, matching
				# the authored form byte-faithfully.
				d["grants"] = grants.duplicate()
			if authored_native_targets:
				# the resolver owns the conditions in the native form — no top-level copy
				d["targets"] = targets_resolver().to_dict()
			else:
				d["targeting_policy"] = policy_key(targeting_policy)
				var conds: Array = []
				for c: EffectCondition in conditions:
					conds.append(c.to_dict())
				d["conditions"] = conds
			if not authored_native_trigger and subject_filter != SubjectFilter.SELF:
				d["subject"] = subject_key(subject_filter)
			if not authored_native_trigger and not subject_elements.is_empty():
				d["subject_elements"] = subject_elements
			if chance != 1.0:
				d["chance"] = chance
			if op == Op.MUL:
				d["op"] = "mul"
			if not tracker_spec.is_empty():
				d["tracker"] = tracker_spec.duplicate()
			if not status_id.is_empty():
				d["status"] = {"id": status_id, "duration": status_duration, "stacks": status_stacks}
			if not spawn_id.is_empty():
				d["spawn"] = {"id": spawn_id, "count": spawn_count}
			return d


# ── STANDING helpers ─────────────────────────────────────────────────────────────────
# (Membership — "does this standing effect apply to unit u right now?" — lives in
# LiveEffects, the one evaluator; the old per-kind matches_card gate is gone with it.)

# A standing effect is one whose trigger's temporal mode is "while" — live until its
# tracker dies, folded at read time, never dispatched. Both authoring forms land here:
# native {"trigger": {"kind": "while"}} and the legacy card-scoped modifier shim.
func is_standing() -> bool:
	return trigger_resolver() is TriggerResolver.While


# A composition grant: a standing effect whose payload is a component set instead of a stat
# fold. Folded by LiveEffects.effective_composition (Layer 1); naturally invisible to the
# stat fold — its standing_attribute() is "", which never equals a foldable attr.
func is_composition_grant() -> bool:
	return is_standing() and not grants.is_empty()


# The attributes the read-time fold actually serves (get_attribute consults LiveEffects
# for exactly these). Pools (current health/shield, side resources) are stored state and
# can never be standing targets — their BASE is what folds (see FOLDABLE_MAP).
const FOLDABLE_ATTRS: Array[String] = ["max_health", "attack", "speed", "cost", "max_shield", "dodge_bonus", "crit_chance_bonus", "crit_multiplier_bonus", "strikes"]
# Pool-named authored attributes → the base each one folds into when authored standing:
# a "while +1 health" means max health, a "while +1 shield" means the shield base the
# pool refreshes to (and reads against) — never the pool itself.
const FOLDABLE_MAP := {"health": "max_health", "shield": "max_shield"}


# The CardInstance attribute a standing effect folds into. Legacy modifiers carry it via
# their key; native effects use the triggered vocabulary, mapped through FOLDABLE_MAP
# (a when-effect on "health"/"shield" writes the pool instead).
func standing_attribute() -> String:
	if kind == Kind.MODIFIER:
		return CARD_ATTR.get(key, "")
	return FOLDABLE_MAP.get(attribute, attribute)


func card_attribute() -> String:
	return CARD_ATTR.get(key, "")


func amount_int() -> int:
	return int(round(amount))


# ── enum <-> string ──────────────────────────────────────────────────────────────────

static func _str_trigger(s: String) -> Trigger:
	match s:
		"on_play":         return Trigger.ON_PLAY
		"on_death":        return Trigger.ON_DEATH
		"on_attack":       return Trigger.ON_ATTACK
		"on_damage_taken": return Trigger.ON_DAMAGE_TAKEN
		"permanent":       return Trigger.PERMANENT
		"on_turn_start":   return Trigger.ON_TURN_START
		"on_turn_end":     return Trigger.ON_TURN_END
		"on_activate":     return Trigger.ON_ACTIVATE
	return Trigger.ON_PLAY


static func _str_policy(s: String) -> TargetingPolicy:
	match s:
		"self":           return TargetingPolicy.SELF
		"single_nearest": return TargetingPolicy.SINGLE_NEAREST
		"single_random":  return TargetingPolicy.SINGLE_RANDOM
		"all_enemies":    return TargetingPolicy.ALL_ENEMIES
		"all_allies":     return TargetingPolicy.ALL_ALLIES
		"all":            return TargetingPolicy.ALL
		"manual":         return TargetingPolicy.MANUAL
		"attack_target":  return TargetingPolicy.ATTACK_TARGET
		"subject":        return TargetingPolicy.SUBJECT
		"attacker":       return TargetingPolicy.ATTACKER
		"manual_slot":    return TargetingPolicy.MANUAL_SLOT
	return TargetingPolicy.SELF


static func _str_role(s: String) -> Role:
	return Role.TARGET if s == "target" else Role.SOURCE


static func role_key(r: Role) -> String:
	return "target" if r == Role.TARGET else "source"


static func _str_subject(s: String) -> SubjectFilter:
	match s:
		"self":  return SubjectFilter.SELF
		"ally":  return SubjectFilter.ALLY
		"enemy": return SubjectFilter.ENEMY
		"any":   return SubjectFilter.ANY
	return SubjectFilter.SELF


static func subject_key(f: SubjectFilter) -> String:
	match f:
		SubjectFilter.SELF:  return "self"
		SubjectFilter.ALLY:  return "ally"
		SubjectFilter.ENEMY: return "enemy"
		SubjectFilter.ANY:   return "any"
	return "self"


static func trigger_key(t: Trigger) -> String:
	match t:
		Trigger.ON_PLAY:         return "on_play"
		Trigger.ON_DEATH:        return "on_death"
		Trigger.ON_ATTACK:       return "on_attack"
		Trigger.ON_DAMAGE_TAKEN: return "on_damage_taken"
		Trigger.PERMANENT:       return "permanent"
		Trigger.ON_TURN_START:   return "on_turn_start"
		Trigger.ON_TURN_END:     return "on_turn_end"
		Trigger.ON_ACTIVATE:     return "on_activate"
	return "on_play"


static func policy_key(p: TargetingPolicy) -> String:
	match p:
		TargetingPolicy.SELF:           return "self"
		TargetingPolicy.SINGLE_NEAREST: return "single_nearest"
		TargetingPolicy.SINGLE_RANDOM:  return "single_random"
		TargetingPolicy.ALL_ENEMIES:    return "all_enemies"
		TargetingPolicy.ALL_ALLIES:     return "all_allies"
		TargetingPolicy.ALL:            return "all"
		TargetingPolicy.MANUAL:         return "manual"
		TargetingPolicy.ATTACK_TARGET:  return "attack_target"
		TargetingPolicy.SUBJECT:        return "subject"
		TargetingPolicy.ATTACKER:       return "attacker"
		TargetingPolicy.MANUAL_SLOT:    return "manual_slot"
	return "self"
