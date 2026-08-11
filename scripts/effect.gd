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
#   • CUSTOM      — a code hook keyed by `custom_id` (EffectHooks BURNED in the effect-cleanse;
#                   the kind parses for old in-test dicts but dispatches nothing), for logic the schema can't
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
	ON_ACT,          # fired for a unit when ITS turn comes up in the speed-ordered combat loop
					 # (the `act` event — "activate" belongs to the ability mechanism now)
}

# Sentinel for "apply this status for its own default duration" (the applier didn't override it).
const STATUS_DURATION_DEFAULT := -9999

# TARGETING REMOVED (targeting-cleanup demolition); CONTENT FORGOTTEN (effect-cleanse,
# user ruling 2026-08-11): all authored effect payloads were stripped from data/ — nothing
# migrates; every effect is re-authored in the new schema as the rebuild reaches its
# container (git history holds the old blocks as reference). NEEDS: the effect-targeting
# authority — the injected component that decides WHO an effect affects, the "who" beside
# the trigger's "when". The authored vocabulary it must serve (spec, not data now):
#   · self / participant (event origin | destination) — a direct reference, no search
#   · auto (nearest | random, count N) — an automatic pick among condition-passing units
#   · all (+ allegiance conditions) — everyone the conditions admit
#   · manual — the unit the player PICKS; the conditions are the eligibility gate the UI enforces
#   · manual_slot — a picked SQUARE (possibly empty), own-side only (a rule the old code kept
#     in the UI layer — the rebuilt authority must own it)
#   · at_location (from / shape / layer / half / count) — position-first: name where you
#     resolve FROM and what shape that implies, get game objects back
#   (the `side` kind is DEAD — side payloads are targetless, TARGETING_DESIGN.md §2/§10)
# Cross-cutting requirements the old system answered piecemeal (see TECH_DEBT_BRIEF.md §1-2):
# one authority answering BOTH verbs (enumerate targets AND does-it-reach-this-candidate, with
# one anchor semantics so the two can never disagree), a declared gesture requirement per kind
# (none / unit pick / slot pick), legality ("is there any legal play right now" — the
# prohibit-non-ops viability rule lived here as an implicit condition), and heterogeneous
# returns (units, a CombatSide, ground slots).

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
# (The verbatim targeting round-trip — _native_targets / targeting_policy_raw — died with
# the content strip: nothing old-language remains to preserve, and to_dict emits no
# targeting. The rebuilt authority defines the one surviving authored form.)
# Legacy/compat trigger mirrors (the TRIGGER side is untouched by this demolition; its own
# consolidation is the next initiative — see TECH_DEBT_BRIEF.md §1).
var trigger: Trigger = Trigger.ON_PLAY
var subject_filter: SubjectFilter = SubjectFilter.SELF
var subject_elements: Array = []   # legacy companion of `trigger`; folded into the resolver
# The effect's authored CONDITIONS (shared predicate grammar — EffectCondition). Still parsed:
# the INTERCEPTOR match gate evaluates them, and legacy TRIGGERED effects round-trip them.
# Their other historical consumer — targeting eligibility — is demolished with targeting.
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
# THROWAWAY SEAM (agreed 2026-08-03): whether this effect's amount multiplies by its holding
# status's stack count (today's blanket behavior, so it defaults true and nothing changes).
# Burning authors false — fire deals 1 whatever the pile. This is deliberately a dumb bool,
# NOT a half-general "amount_per" field: the real replacement is amounts-as-expressions
# ("damage equal to its speed"), which supersedes this wholesale when it arrives.
var per_stack: bool = true
# The RESTRIKE chance ("each flame beyond the first may burn again" — user 2026-08-03):
# when > 0 and this effect fires from a STACKED status container, each stack PAST THE FIRST
# repeats the whole effect once, gated by its own roll at this chance. Each success is its
# own damage INSTANCE — so damage riders roll per repeat, and a tall fire threatens ignition
# repeatedly. 0 = off (one activation, today's behavior). Consumed only at the grouped
# dispatch sites (stacks live there); a stackless firing (spell, arrival touch) ignores it.
var per_stack_chance: float = 0.0
# Which LAYER receives the status: "units" (default — today's behavior, each resolved unit)
# or "ground" (the BOARD SLOT at the effect's coordinates — the MANUAL_SLOT picked cell, or
# the anchor coords). Layer addressing lives on the PAYLOAD (WHAT is delivered); WHO/WHERE
# stays the target resolver's job. See EffectSystem._apply_ground_status / SLOT_LAYER_DESIGN.md.
var status_layer: String = "units"

# RIDERS — follow-ons carried by this effect's damage, applied to the unit that took it.
# Each entry: {"chance": float, "status": {"id", "duration", "stacks"}}. Rolled ONCE PER
# DAMAGE INSTANCE, flat: an effect dealing 3 in one instance rolls exactly as often as one
# dealing 1 (the amount is not a multiplier — settled with the user 2026-08-03). More rolls
# means more instances of damage, which is a repetition question, not a rider question.
# Only fires when damage ACTUALLY LANDED (delta != 0) — an intercepted-away hit carries
# nothing, because the rider rides the damage, not the attempt.
# GENERAL in the right axis: not "burning ignites" but "this damage carries a follow-on".
# Frost damage that chills or poison damage that spreads use the identical seam.
var riders: Array = []

# NAMED-EFFECT reference (see NamedEffects): non-empty when this effect was authored as
# {"named": "<id>", ...} — the registry template merged under the authored keys at parse
# time (authored wins). `_named_authored` holds the authored dict VERBATIM: to_dict returns
# it unchanged, so the reference round-trips byte-faithfully and the expansion never leaks
# into saved data. (Consequence: post-parse field mutations don't serialize for a named
# effect — acceptable; nothing edits parsed effects and re-serializes them.)
var named_id: String = ""
var _named_authored: Dictionary = {}


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
# ── EVAL ANNOTATION (the enemy engine's channel pricing — STATUS_EVAL_BRIEF.md) ──
# Hand-AUTHORED, flat (applied once per carrier; stack scaling lives on StatusData.eval_mods):
# how this effect's PRESENCE moves its carrier in the engine's three channels. Keys:
#   "threat" / "exposure" / "value"             — adds (damage points per round for the first
#                                                 two, value-units for the third)
#   "threat_mul" / "exposure_mul" / "value_mul" — multipliers (applied after ALL adds)
# Absent = this effect is invisible to the engine (today's behavior, never wrong-and-loud).
# The number is a human judgment written next to the effect — NEVER derived from what the
# effect does (deriving is the discarded channel-taxonomy appraiser). Folded at BoardState
# capture by EvalChannels; the game rules never read it.
var eval_mods: Dictionary = {}

const EVAL_KEYS: Array[String] = ["threat", "exposure", "value",
		"threat_mul", "exposure_mul", "value_mul"]

# Probabilistic gate, rolled once before the effect resolves: the effect fires with this chance
# (1.0 = always). A declarative condition, separate from what the effect does. See EffectSystem.
var chance: float = 1.0
var op: Op = Op.ADD
var filter: Dictionary = {}   # card selection predicate for scope=CARD


# THE NAMED-EFFECT REGISTRY, reached by PATH rather than by class name — a landmine, not a
# style choice. Content registries parse their effects from `_static_init` (RelicData,
# CardData, StatusData, …), and during another script's static initialisation a sibling
# class_name may resolve to a script object that is not compiled yet: the static call then
# dies with "Nonexistent function 'get_named' in base 'GDScript'". Whether it happens at all
# is script LOAD ORDER — relics broke, cards did not, and either could flip. `load()` at call
# time forces the script fully in, and the result is cached for every later parse. Never
# reintroduce a direct `NamedEffects.…` call in this parser.
static var _named_lib: Object = null

static func _named_registry() -> Object:
	if _named_lib == null:
		_named_lib = load("res://scripts/named_effects.gd")
		if _named_lib == null:
			push_error("Effect: the named-effect registry script is missing — keywords will not expand")
	return _named_lib


# The one canonical parser. Kind is explicit ("kind") or inferred: a "key" → MODIFIER, a
# "custom" → CUSTOM, otherwise TRIGGERED — so legacy data needs no migration.
static func from_dict(d: Dictionary) -> Effect:
	# NAMED-EFFECT expansion: merge the registry template UNDER the authored keys (authored
	# wins) and parse the merged dict through this same function — the template carries no
	# "named" key (NamedEffects refuses chains), so the recursion is one level by construction.
	var named := str(d.get("named", ""))
	if not named.is_empty():
		var registry := _named_registry()
		var template: Dictionary = {} if registry == null else registry.get_named(named)
		if template.is_empty():
			push_error("Effect: unknown named effect '%s' — parsing the call site alone — %s" % [named, d])
		var merged := template.duplicate(true)
		for k: Variant in d:
			if str(k) != "named":
				merged[k] = d[k]
		# "Blind X": the keyword's magnitude is the effect's `amount` (call site's if it
		# authored one, else the template's default), substituted into every "$X" the
		# template wrote — stacks, eval price, whatever the keyword scales. See NamedEffects.
		if registry != null:
			merged = registry.substitute(merged, float(merged.get("amount", 0))) as Dictionary
		var ne := from_dict(merged)
		ne.named_id = named
		ne._named_authored = d.duplicate(true)
		return ne
	var e := Effect.new()
	e.amount = float(d.get("amount", 0))
	e.chance = float(d.get("chance", 1.0))
	e._parse_eval(d)
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
		e.per_stack        = bool(d.get("per_stack", true))
		e.per_stack_chance = float(d.get("per_stack_chance", 0.0))
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
		e.status_layer    = str(st.get("layer", "units"))
		if not e.status_layer in ["units", "ground"]:
			push_error("Effect: unknown status layer '%s' (units/ground) — %s" % [e.status_layer, d])
			e.status_layer = "units"
	# Optional damage RIDERS, valid on any event-driven (TRIGGERED) effect that deals damage.
	for r_v: Variant in (d.get("riders", []) as Array):
		var rd: Dictionary = r_v as Dictionary
		if rd == null:
			continue
		var rst: Dictionary = rd.get("status", {})
		if str(rst.get("id", "")).is_empty():
			push_error("Effect: a rider with no status payload does nothing — %s" % d)
			continue
		e.riders.append({
			"chance": float(rd.get("chance", 1.0)),
			"status_id": str(rst.get("id", "")),
			"status_duration": int(rst.get("duration", STATUS_DURATION_DEFAULT)),
			"status_stacks": int(rst.get("stacks", 1))})
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


# Parses the authored "eval" annotation (any kind may carry one — see eval_mods above).
# Unknown keys fail loud: a typoed channel silently contributing nothing is exactly the
# quiet degradation the absent-is-invisible rule must NOT extend to authored numbers.
func _parse_eval(d: Dictionary) -> void:
	var ev_v: Variant = d.get("eval", null)
	if ev_v == null:
		return
	if not ev_v is Dictionary:
		push_error("Effect: 'eval' must be a dictionary of channel numbers — %s" % [d])
		return
	for k: Variant in (ev_v as Dictionary):
		if not str(k) in EVAL_KEYS:
			push_error("Effect: unknown eval channel '%s' (%s) — %s" % [k, EVAL_KEYS, d])
			continue
		eval_mods[str(k)] = float((ev_v as Dictionary)[k])


# The fold's read accessors: a channel's add (absent = 0) and multiplier (absent = 1).
func eval_add(p_channel: String) -> float:
	return float(eval_mods.get(p_channel, 0.0))


func eval_mul(p_channel: String) -> float:
	return float(eval_mods.get(p_channel + "_mul", 1.0))


func _eval_out(d: Dictionary) -> void:
	if not eval_mods.is_empty():
		d["eval"] = eval_mods.duplicate()


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


# TARGETING REMOVED — PROHIBIT NON-OPS demolished with it. NEEDS (a user-designed rule, see
# PROHIBIT_NONOPS memory/initiative): every effect whose payload is a stat change on a UNIT
# carried an implicit, never-authored VIABILITY condition — "would this change actually do
# anything to the unit in front of it" — installed here at parse into the ordinary conditions
# list, so everything downstream inherited it at once: an AoE heal skipped the unwounded, a
# manual heal refused to light them up, the enemy AI stopped picking them, and a spell whose
# every effect was a no-op had NO LEGAL PLAY at all. Exclusions: CUSTOM (opaque payload),
# standing/while (a fold has no no-op moment, and the condition would recurse into
# get_attribute), MODIFIER/INTERCEPTOR (no resolved unit), status/spawn/grant payloads (the
# attribute is not what the effect does), side stats (the target is a player). The rebuilt
# targeting authority must own this rule — it is an ELIGIBILITY rule, and eligibility is
# targeting's second verb.


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
	if d.get("targets", null) is Dictionary \
			and not str((d["targets"] as Dictionary).get("kind", "all")) in ["all", "self"]:
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


# Load-time validation of side-stat payloads (draw/discard/mana/max_mana) — FAIL LOUD.
# The `side` TARGET KIND is DEAD (effect-cleanse demolition): a side payload is TARGETLESS —
# its recipient is derivable (the holder's own side via the allegiance anchor), so it
# authors no target at all (TARGETING_DESIGN.md §2/§10; every authored use was `of: own`).
func _validate_side_targets(d: Dictionary) -> void:
	var tv: Variant = d.get("targets", null)
	if tv is Dictionary and str((tv as Dictionary).get("kind", "")) == "side":
		push_error("Effect: the 'side' target kind is dead — side payloads are targetless — %s" % [d])
	if not StatMutation.is_side_stat(attribute):
		return
	if kind != Kind.TRIGGERED:
		push_error("Effect: a side stat is only valid on a triggered effect — %s" % [d])
	# "self" passes as authored: it is the vacuous legacy default old serializers spelled
	# out on every legacy triggered effect.
	if tv is Dictionary or not str(d.get("targeting_policy", "")) in ["", "self"]:
		push_error("Effect: side stat '%s' is targetless — it authors no targets — %s" % [attribute, d])
	if not status_id.is_empty():
		push_error("Effect: a side-stat effect cannot also apply a status — %s" % [d])
	if not spawn_id.is_empty():
		push_error("Effect: a side-stat effect cannot also spawn units — %s" % [d])


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


# Captures the authored targeting VERBATIM — no interpretation, no resolver, no mirror
# (targeting-cleanup demolition; see the NEEDS block at the top of this file). The one
# subtlety kept: a native form's conditions still parse into `conditions` so the shared
# grammar stays load-validated (mutation-form fencing below) — the LIST is not re-emitted
# for native effects (the verbatim dict already carries them).
func _parse_targets(d: Dictionary) -> void:
	# Targeting itself is uninterpreted (demolished) and never stored — but a native
	# "targets" dict still carries the effect's CONDITIONS, which the shared predicate
	# grammar load-validates (mutation-form fencing below).
	var tv: Variant = d.get("targets", null)
	if tv is Dictionary:
		conditions = TriggerResolver._parse_conditions((tv as Dictionary).get("conditions", []))


# Serialises back to the authored shape. Exercised for persisted (overridden) CARD effects,
# which are TRIGGERED — so that path matches the legacy dict exactly.
func to_dict() -> Dictionary:
	# A named effect serialises as it was AUTHORED — the reference, never the expansion
	# (byte-faithful by construction; see _named_authored).
	if not named_id.is_empty():
		return _named_authored.duplicate(true)
	match kind:
		Kind.MODIFIER:
			var d := {"kind": "modifier", "key": key, "amount": amount}
			if op == Op.MUL:
				d["op"] = "mul"
			if not filter.is_empty():
				d["filter"] = filter
			if not conditions.is_empty():
				var mconds := TriggerResolver.conditions_to_dicts(conditions)
				if not mconds.is_empty():
					d["conditions"] = mconds
			_eval_out(d)
			return d
		Kind.CUSTOM:
			var cd := {
				"kind":    "custom",
				"custom":  custom_id,
				"trigger": _trigger_out(),
			}
			if not material.is_empty():
				cd["material"] = material
			# No targeting is emitted: the old language is forgotten (content stripped, saves
			# scrubbed); the rebuilt authority's schema is the only targeting ever written again.
			if not authored_native_trigger and subject_filter != SubjectFilter.SELF:
				cd["subject"] = subject_key(subject_filter)
			_eval_out(cd)
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
					var iconds := TriggerResolver.conditions_to_dicts(conditions)
					if not iconds.is_empty():
						idd["conditions"] = iconds
			if channel != &"":
				idd["channel"] = String(channel)
			if op == Op.MUL:
				idd["op"] = "mul"
			if chance != 1.0:
				idd["chance"] = chance
			_eval_out(idd)
			return idd
		_:
			var d := {"trigger": _trigger_out()}
			if grants.is_empty():
				d["attribute"] = attribute
				d["amount"]    = amount_int()
				if not per_stack:
					d["per_stack"] = false
				if per_stack_chance > 0.0:
					d["per_stack_chance"] = per_stack_chance
			else:
				# A grant's payload IS the component set — no attribute/amount keys, matching
				# the authored form byte-faithfully.
				d["grants"] = grants.duplicate()
			# No targeting is emitted (see the CUSTOM branch note); conditions keep their
			# top-level spelling so the predicate grammar round-trips.
			var tconds := TriggerResolver.conditions_to_dicts(conditions)
			if not tconds.is_empty():
				d["conditions"] = tconds
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
				if status_layer != "units":   # the default stays unspelled — byte-faithful round trip
					d["status"]["layer"] = status_layer
			if not riders.is_empty():
				var rl: Array = []
				for r: Dictionary in riders:
					var rdd: Dictionary = {"status": {"id": r["status_id"],
							"duration": r["status_duration"], "stacks": r["status_stacks"]}}
					if float(r["chance"]) != 1.0:
						rdd["chance"] = r["chance"]
					rl.append(rdd)
				d["riders"] = rl
			if not spawn_id.is_empty():
				d["spawn"] = {"id": spawn_id, "count": spawn_count}
			_eval_out(d)
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
		"on_activate":     return Trigger.ON_ACT
	return Trigger.ON_PLAY


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
		Trigger.ON_ACT:          return "on_activate"   # the legacy authored key, re-emitted byte-faithfully
	return "on_play"
