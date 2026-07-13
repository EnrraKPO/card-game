class_name TargetResolver
extends RefCounted

# The injectable component that decides WHO an effect affects — the "who" of an effect,
# the counterpart of TriggerResolver's "when". Every targeted Effect holds exactly one;
# resolution is one uniform call for every kind:
#
#     resolve(event, holder, context) -> Array   # CardInstance or CombatSide (the Side kind);
#                                                # EffectSystem dispatches on target type
#
# The activating GameEvent is part of the shared context (null for a transient use — a
# spell cast / ability activation has no event). Kinds differ only in which part of that
# context they consult (inner classes — same single-file rule as TriggerResolver: the
# factory runs during other classes' @static_initializer):
#   • All          — every unit on the board that passes the conditions.
#   • Auto         — automatic pick among condition-passing units by a criterion
#                    (nearest / random), `count` at a time (default 1).
#   • Manual       — the unit the player picked (context.manual_target); the conditions
#                    are the eligibility gate the targeting UI enforces.
#   • ManualSlot   — the deliberate outlier: the player picks a SLOT (possibly empty) on
#                    their side; resolves to no units — the slot flows through context to
#                    the effect's custom hook (material delivery).
#   • Participant  — a direct reference to the event's origin/destination (or the holder
#                    itself), returned iff it passes the conditions. No event, or an event
#                    without that participant → no targets, by construction.
#                    participant "holder" is canonically spelled {"kind": "self"} — the
#                    SELF target kind ("applies to the holder"), which is how identity
#                    targeting is expressed now that the relation condition form is gone.
#
# Conditions are the same plain EffectCondition PREDICATE grammar as everywhere else
# (stat / status / composition / allegiance-to-owner). One grammar, three sockets:
# trigger → targets → payload. Identity ("the holder itself") is never a condition — it
# is the self kind; legacy {"relation": "self"} entries in a native condition list are
# extracted into it at parse.
#
# Authoring: the effect's "targets" key (native form). The legacy "targeting_policy" string
# maps losslessly at load (see from_legacy) — zero data migration:
#   { "targets": { "kind": "self" } }
#   { "targets": { "kind": "all", "conditions": [ ... ] } }
#   { "targets": { "kind": "auto", "criterion": "nearest", "count": 1, "conditions": [ ... ] } }
#   { "targets": { "kind": "manual", "conditions": [ ... ] } }
#   { "targets": { "kind": "manual_slot", "conditions": [ ... ] } }
#   { "targets": { "kind": "participant", "participant": "origin", "conditions": [ ... ] } }
#   { "targets": { "kind": "side", "of": "own"|"opponent" } }   — a PLAYER, not a unit (see Side)

const CRITERIA: Array[String] = ["nearest", "random"]
const PARTICIPANTS: Array[String] = ["holder", "origin", "destination"]

# Conditions gating the resolved unit(s) — shared grammar, shared field across kinds.
# NOTE: for legacy-parsed effects this is the SAME array instance as Effect.conditions
# (the legacy mirror), so the pre-resolution eligibility consumers (SpellCaster UI,
# enemy AI) and the resolver can never disagree.
var conditions: Array = []   # Array[EffectCondition]


func resolve(_event: GameEvent, _holder: CardInstance, _context: EffectContext) -> Array:
	return []


func to_dict() -> Dictionary:
	return {}


func _base_dict(kind: String) -> Dictionary:
	var d := {"kind": kind}
	if not conditions.is_empty():
		d["conditions"] = TriggerResolver.conditions_to_dicts(conditions)
	return d


func _passing(units: Array, holder: CardInstance) -> Array:
	return units.filter(func(u: CardInstance) -> bool:
		return TriggerResolver.conditions_pass(conditions, u, holder))


# ── Kinds ────────────────────────────────────────────────────────────────────────────

class All extends TargetResolver:
	func resolve(_event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		return _passing(TargetResolver.board_units(context), holder)

	func to_dict() -> Dictionary:
		return _base_dict("all")


class Auto extends TargetResolver:
	var criterion: String = "nearest"
	var count: int = 1

	func resolve(_event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		var pool := _passing(TargetResolver.board_units(context), holder)
		if pool.is_empty():
			return pool
		match criterion:
			"random":
				pool.shuffle()
			_:   # nearest — row/col tie-break keeps the legacy scan-order determinism
				pool.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
					var da := TargetResolver.board_distance(holder, a)
					var db := TargetResolver.board_distance(holder, b)
					if da != db:
						return da < db
					if a.row != b.row:
						return a.row < b.row
					return a.col < b.col)
		return pool.slice(0, count)

	func to_dict() -> Dictionary:
		var d := _base_dict("auto")
		d["criterion"] = criterion
		if count != 1:
			d["count"] = count
		return d


class Manual extends TargetResolver:
	func resolve(_event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		if context.manual_target == null:
			return []
		return _passing([context.manual_target], holder)

	func to_dict() -> Dictionary:
		return _base_dict("manual")


class ManualSlot extends TargetResolver:
	# Resolves to no UNITS — the picked slot rides the context into the effect's custom
	# hook (see EffectHooks.deliver_material). The conditions still gate an OCCUPIED pick
	# (SpellCaster consults them pre-resolution, like Manual's eligibility).
	func resolve(_event: GameEvent, _holder: CardInstance, _context: EffectContext) -> Array:
		return []

	func to_dict() -> Dictionary:
		return _base_dict("manual_slot")


class Side extends TargetResolver:
	# A PLAYER side as the target — the resolve() seam widens to a heterogeneous Array here
	# (CardInstance or CombatSide; EffectSystem dispatches on type, mirroring Resolver.submit).
	# `of` is relative to the HOLDER's owner ("own"/"opponent"); run-scope effects anchor via
	# their perspective card, same as trigger_global. No conditions: players have no stats or
	# composition to predicate on (load validation rejects authored ones — see Effect).
	var of: String = "own"

	func resolve(_event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		if context == null or holder == null or holder.owner < 0:
			return []
		var want := holder.owner if of == "own" else 1 - holder.owner
		var side := context.side_for(want)
		return [] if side == null else [side]

	func to_dict() -> Dictionary:
		var d := _base_dict("side")
		d["of"] = of
		return d


class Participant extends TargetResolver:
	var participant: String = "holder"

	func resolve(event: GameEvent, holder: CardInstance, _context: EffectContext) -> Array:
		var unit: CardInstance = null
		match participant:
			"holder":      unit = holder
			"origin":      unit = event.origin if event != null else null
			"destination": unit = event.destination if event != null else null
		if unit == null:
			return []
		return _passing([unit], holder)

	func to_dict() -> Dictionary:
		# participant "holder" serializes as its canonical spelling: the self kind.
		if participant == "holder":
			return _base_dict("self")
		var d := _base_dict("participant")
		d["participant"] = participant
		return d


# ── Parsing ──────────────────────────────────────────────────────────────────────────

# Native form (the "targets" dictionary).
static func parse(d: Dictionary) -> TargetResolver:
	var conds := TriggerResolver._parse_conditions(d.get("conditions", []))
	match str(d.get("kind", "")):
		"self":
			return _participant("holder", conds)
		"auto":
			var auto := Auto.new()
			auto.criterion = str(d.get("criterion", "nearest"))
			auto.count = maxi(1, int(d.get("count", 1)))
			auto.conditions = conds
			return auto
		"manual":
			var man := Manual.new()
			man.conditions = conds
			return man
		"manual_slot":
			var slot := ManualSlot.new()
			slot.conditions = conds
			return slot
		"side":
			var side := Side.new()
			side.of = str(d.get("of", "own"))
			if not side.of in ["own", "opponent"]:
				push_error("TargetResolver: unknown side selector '%s' — %s" % [side.of, d])
				side.of = "own"
			return side
		"participant":
			var part := Participant.new()
			part.participant = str(d.get("participant", "holder"))
			part.conditions = conds
			return part
		_:   # "all" (and anything unrecognised degrades to it — fail visible, not crashy)
			# Pre-gate native data spelled self-targeting as all + {"relation": "self"};
			# the identity entry is structural, so such a dict IS the self kind.
			if TriggerResolver._has_identity(d.get("conditions", [])):
				return _participant("holder", conds)
			var all := All.new()
			all.conditions = conds
			return all


# Maps a legacy policy string onto a resolver. `conditions` is the effect's legacy
# condition list (passed BY REFERENCE — see the `conditions` field note). The legacy
# implicit scopes become relation conditions; SUBJECT resolves to the participant that
# was the legacy subject for the effect's trigger (destination only for on_damage_taken).
static func from_legacy(policy_key: String, conditions: Array, subject_is_destination: bool) -> TargetResolver:
	match policy_key:
		"self":
			return _participant("holder", conditions)
		"single_nearest":
			return _auto("nearest", conditions, true)
		"single_random":
			return _auto("random", conditions, true)
		"all_enemies":
			return _all(conditions, "enemy")
		"all_allies":
			return _all(conditions, "ally")
		"manual":
			var man := Manual.new()
			man.conditions = conditions
			return man
		"manual_slot":
			var slot := ManualSlot.new()
			slot.conditions = conditions
			return slot
		"attack_target":
			return _participant("destination", conditions)
		"attacker":
			return _participant("origin", conditions)
		"subject":
			return _participant("destination" if subject_is_destination else "origin", conditions)
	var all := All.new()   # "all"
	all.conditions = conditions
	return all


static func _participant(which: String, conditions: Array) -> Participant:
	var part := Participant.new()
	part.participant = which
	part.conditions = conditions
	return part


# Legacy nearest/random searched only the OPPOSING board; the implicit scope becomes an
# explicit allegiance condition prepended to the authored ones (the shared array itself is
# left untouched — the effect's legacy mirror must serialize back byte-identical).
static func _auto(criterion: String, conditions: Array, enemies_only: bool) -> Auto:
	var auto := Auto.new()
	auto.criterion = criterion
	auto.conditions = ([EffectCondition.from_dict({"allegiance": "enemy"})] + conditions) if enemies_only else conditions
	return auto


static func _all(conditions: Array, allegiance: String) -> All:
	var all := All.new()
	all.conditions = [EffectCondition.from_dict({"allegiance": allegiance})] + conditions
	return all


# The compat TargetingPolicy enum value — kept on Effect for consumers that classify
# effects without resolving (SpellCaster's mode checks, enemy-AI heuristics). Derived,
# never authoritative.
static func legacy_policy_for(resolver: TargetResolver) -> Effect.TargetingPolicy:
	if resolver is Manual:
		return Effect.TargetingPolicy.MANUAL
	if resolver is ManualSlot:
		return Effect.TargetingPolicy.MANUAL_SLOT
	if resolver is Participant:
		match (resolver as Participant).participant:
			"origin":      return Effect.TargetingPolicy.ATTACKER
			"destination": return Effect.TargetingPolicy.ATTACK_TARGET
			_:             return Effect.TargetingPolicy.SELF
	if resolver is Auto:
		return Effect.TargetingPolicy.SINGLE_RANDOM if (resolver as Auto).criterion == "random" \
				else Effect.TargetingPolicy.SINGLE_NEAREST
	return Effect.TargetingPolicy.ALL


# ── Shared helpers ───────────────────────────────────────────────────────────────────

static func board_units(context: EffectContext) -> Array:
	var out: Array = []
	for board: Array in [context.player_board, context.enemy_board]:
		for row: Array in board:
			for cell: Variant in row:
				if cell != null:
					out.append(cell)
	return out


# Board distance from the holder to a candidate. Cross-board: COLUMN DEPTH DOMINATES
# and the mirrored lane offset only breaks ties within a column — the same lexicographic
# geometry as TargetingStrategy.dist, so attack targeting and effect targeting agree on
# what "nearest" means. Same side: plain Manhattan, scaled by the same factor so mixed
# ally/enemy pools stay commensurate.
static func board_distance(holder: CardInstance, cand: CardInstance) -> int:
	if cand.owner == holder.owner:
		return (absi(holder.row - cand.row) + absi(holder.col - cand.col)) * BoardData.ROWS
	var lane_offset: int = absi(holder.row + cand.row - (BoardData.ROWS - 1))
	var depth: int
	if holder.owner == 0:
		depth = BoardData.COLS + cand.col - holder.col
	else:
		depth = BoardData.COLS + holder.col - cand.col
	return depth * BoardData.ROWS + lane_offset
