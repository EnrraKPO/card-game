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
#   { "targets": { "kind": "at_location", "from": "holder", "shape": "around",
#                  "layer": "ground", "half": "same", "count": 0, "conditions": [ ... ] } }
#         — THE LOCATION SOCKET (see AtLocation): name where you resolve FROM and what
#           SHAPE that implies, get game objects back. Every key is optional, and the
#           defaults are exactly what "at_location" meant before it took any.
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


func _passing(units: Array, owner: int) -> Array:
	return units.filter(func(u: CardInstance) -> bool:
		return TriggerResolver.conditions_pass(conditions, u, owner))


# The allegiance anchor for THIS resolution: the run-scope player anchor when the context
# carries one (relics/upgrades — see EffectContext.owner_anchor), else the holder's side.
# Targeting stays spatially anchored on the holder; only "ally"/"enemy" reads shift.
static func _anchor(holder: CardInstance, context: EffectContext) -> int:
	if context != null:
		return TriggerResolver.anchor_owner(holder, context.owner_anchor)
	return TriggerResolver.anchor_owner(holder, TriggerResolver.OWNER_FROM_HOLDER)


# ── Kinds ────────────────────────────────────────────────────────────────────────────

class All extends TargetResolver:
	func resolve(_event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		return _passing(TargetResolver.board_units(context), TargetResolver._anchor(holder, context))

	func to_dict() -> Dictionary:
		return _base_dict("all")


class Auto extends TargetResolver:
	var criterion: String = "nearest"
	var count: int = 1

	func resolve(_event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		var pool := _passing(TargetResolver.board_units(context), TargetResolver._anchor(holder, context))
		if pool.is_empty():
			return pool
		match criterion:
			"random":
				pool.shuffle()
			_:   # nearest — address tie-break keeps the legacy scan-order determinism
				var places := TargetResolver.places_of(context)
				if places != null:
					var from := places.location_of(holder)
					pool.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
						var la := places.location_of(a)
						var lb := places.location_of(b)
						var da := TargetResolver.board_distance(from, la)
						var db := TargetResolver.board_distance(from, lb)
						if da != db:
							return da < db
						if la.row != lb.row:
							return la.row < lb.row
						return la.col < lb.col)
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
		return _passing([context.manual_target], TargetResolver._anchor(holder, context))

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


class AtLocation extends TargetResolver:
	# POSITION-FIRST targeting, and THE EFFECT-SIDE SOCKET onto the location layer
	# (LOCATION_MANAGER_DESIGN.md §4.6; SLOT_LAYER_DESIGN.md §2.4). An effect names two
	# things it understands and gets back GAME OBJECTS:
	#
	#   `from`  — the LOCATION POLICY: where it resolves FROM.
	#   `shape` — the GEOMETRY PROCEDURE: which cells that origin implies.
	#
	# …plus `layer` (whose contents come back — units or ground) and `half` (whether the
	# battle line is a wall for this effect, which is a RULE and so lives here rather than
	# in geometry). AT NO POINT DOES AN EFFECT SEE A COORDINATE: it names a policy, gets
	# objects, and runs its own conditions and mutations exactly as any other kind does.
	#
	# The division of labour is the fence §4.4 draws. Geometry yields an ORDERED LIST OF
	# LOCATIONS and has never heard of a unit; this walks that list, asks the façade what is
	# there, and applies the authored conditions. Geometry never sees a condition; this never
	# does arithmetic. A new shape teaches geometry; a new predicate teaches nobody.
	#
	# Emptiness is an ANSWER (§2.9). No origin, an empty cell, a whole shape with nobody in
	# it — all legal whiffs, no error. Only an unknown policy name is a bug, and that is
	# caught at parse.
	#
	# DEFAULTS REPRODUCE WHAT SHIPPED: from "anchor", shape "here", layer "pieces" — the
	# unit standing at the effect's anchor address, which is what `at_location` meant before
	# it had any parameters. Existing authored data is untouched by construction.

	const POLICIES: Array[String] = ["anchor", "picked", "holder", "origin", "destination"]
	const SHAPES: Array[String] = ["here", "around", "nearest"]
	const LAYERS: Array[String] = ["pieces", "ground"]
	const HALVES: Array[String] = ["any", "same"]

	var from: String = "anchor"
	var shape: String = "here"
	var layer: String = "pieces"
	var half: String = "any"
	var count: int = 0   # 0 = however many the shape finds

	func resolve(event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		if context == null:
			return []
		var origin := _origin(event, holder, context)
		if origin == null:
			return []   # nothing to resolve FROM — a whiff, not a fault
		var out: Array = []
		for loc: BoardLocation in _cells(origin):
			if half == "same" and loc.side != origin.side:
				continue
			var found: Object = _contents(context, loc)
			if found != null:
				out.append(found)
		if layer == "ground":
			# A slot has no stats, no composition and no allegiance — nothing the condition
			# grammar can predicate on. Parse refuses authored conditions here, so there is
			# nothing to apply.
			return out.slice(0, count) if count > 0 else out
		var passing := _passing(out, TargetResolver._anchor(holder, context))
		return passing.slice(0, count) if count > 0 else passing

	# THE LOCATION POLICY. Every branch asks something that already knows; none of them
	# reads a coordinate off the thing it is asking about.
	func _origin(event: GameEvent, holder: CardInstance, context: EffectContext) -> BoardLocation:
		match from:
			"anchor":
				return context.anchor_at
			"picked":
				return context.manual_at
			"holder":
				return _where(context, holder)
			"origin":
				return null if event == null else _where(context, event.origin as CardInstance)
			"destination":
				return null if event == null else _where(context, event.destination as CardInstance)
		return null

	static func _where(context: EffectContext, unit: CardInstance) -> BoardLocation:
		if context.world == null or unit == null:
			return null
		return context.world.location_of(unit)

	# THE GEOMETRY PROCEDURE — pure locations in, pure locations out, in a fixed order.
	func _cells(origin: BoardLocation) -> Array:
		match shape:
			"around":
				return BoardGeometry.neighbours(origin)
			"nearest":
				# Every cell, nearest first, the origin included — "the closest thing to
				# here" has an obvious answer when something is standing on `here`.
				return BoardGeometry.cells_by_distance(origin)
		return [origin]   # "here"

	# THE FAÇADE CROSSING: the one place this kind knows that a layer yields a species.
	func _contents(context: EffectContext, loc: BoardLocation) -> Object:
		if layer == "ground":
			# slot_at, not peek: the ground EXISTS at every real address (SLOT_LAYER_DESIGN.md),
			# and a shape that skipped cells nothing had touched yet would set three neighbours
			# alight and mysteriously miss the fourth.
			return BoardFacade.slot_at(context.world, loc) if context.world != null else null
		return TargetResolver.unit_at(context, loc)

	func to_dict() -> Dictionary:
		var d := _base_dict("at_location")
		if from != "anchor":
			d["from"] = from
		if shape != "here":
			d["shape"] = shape
		if layer != "pieces":
			d["layer"] = layer
		if half != "any":
			d["half"] = half
		if count > 0:
			d["count"] = count
		return d


class Side extends TargetResolver:
	# A PLAYER side as the target — the resolve() seam widens to a heterogeneous Array here
	# (CardInstance or CombatSide; EffectSystem dispatches on type, mirroring Resolver.submit).
	# `of` is relative to the HOLDER's owner ("own"/"opponent"); run-scope effects anchor via
	# their perspective card, same as trigger_global. No conditions: players have no stats or
	# composition to predicate on (load validation rejects authored ones — see Effect).
	var of: String = "own"

	func resolve(_event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		if context == null:
			return []
		var anchor := TargetResolver._anchor(holder, context)
		if anchor < 0:
			return []
		var want := anchor if of == "own" else 1 - anchor
		var side := context.side_for(want)
		return [] if side == null else [side]

	func to_dict() -> Dictionary:
		var d := _base_dict("side")
		d["of"] = of
		return d


class Participant extends TargetResolver:
	var participant: String = "holder"

	func resolve(event: GameEvent, holder: CardInstance, context: EffectContext) -> Array:
		var unit: CardInstance = null
		match participant:
			"holder":      unit = holder
			"origin":      unit = event.origin if event != null else null
			"destination": unit = event.destination if event != null else null
		if unit == null:
			return []
		return _passing([unit], TargetResolver._anchor(holder, context))

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
		"at_location":
			var at := AtLocation.new()
			at.conditions = conds
			at.from = str(d.get("from", "anchor"))
			at.shape = str(d.get("shape", "here"))
			at.layer = str(d.get("layer", "pieces"))
			at.half = str(d.get("half", "any"))
			at.count = maxi(0, int(d.get("count", 0)))
			# Fail loud on a misspelt policy — a silent degrade here is an effect that
			# quietly resolves to nothing forever (the house rule, and §2.9's point that a
			# legal whiff and a bug must not look alike).
			if not at.from in AtLocation.POLICIES:
				push_error("TargetResolver: unknown location policy '%s' %s — %s"
						% [at.from, AtLocation.POLICIES, d])
				at.from = "anchor"
			if not at.shape in AtLocation.SHAPES:
				push_error("TargetResolver: unknown shape '%s' %s — %s"
						% [at.shape, AtLocation.SHAPES, d])
				at.shape = "here"
			if not at.layer in AtLocation.LAYERS:
				push_error("TargetResolver: unknown layer '%s' %s — %s"
						% [at.layer, AtLocation.LAYERS, d])
				at.layer = "pieces"
			if not at.half in AtLocation.HALVES:
				push_error("TargetResolver: unknown half selector '%s' %s — %s"
						% [at.half, AtLocation.HALVES, d])
				at.half = "any"
			if at.layer == "ground" and not conds.is_empty():
				push_error("TargetResolver: ground-layer targeting takes no conditions — "
						+ "a slot has no stats, composition or allegiance to predicate on — %s" % [d])
				at.conditions = []
			return at
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
		"at_location":
			var at := AtLocation.new()
			at.conditions = conditions
			return at
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
	if resolver is AtLocation:
		return Effect.TargetingPolicy.AT_LOCATION
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

# The unit standing at an address, read from the context's own boards — which derive from
# the world when there is one, and are the caller's explicit fixtures when there is not.
# Null = nobody there, which is an answer (§2.9); a location is real by construction, so the
# four hand-rolled bounds guards this used to carry are gone.
static func unit_at(context: EffectContext, at: BoardLocation) -> CardInstance:
	if context == null or at == null:
		return null
	var board: Array = context.player_board if at.side == 0 else context.enemy_board
	if at.row >= board.size():
		return null
	var board_row: Array = board[at.row]
	if at.col >= board_row.size():
		return null
	return board_row[at.col]


static func board_units(context: EffectContext) -> Array:
	var out: Array = []
	for board: Array in [context.player_board, context.enemy_board]:
		for row: Array in board:
			for cell: Variant in row:
				if cell != null:
					out.append(cell)
	return out


# The placement this dispatch reads — the world's, or nothing outside a combat, where
# proximity has no meaning and the pool keeps its enumeration order.
static func places_of(context: EffectContext) -> LocationManager:
	if context == null or context.world == null:
		return null
	return context.world.locations


# Effect targeting's PREFERENCE ordering from one cell to another — NOT a distance
# (LOCATION_MANAGER_DESIGN.md §2.10; BoardGeometry.distance is the real, symmetric one).
# Cross-half: COLUMN DEPTH DOMINATES and the mirrored lane offset only breaks ties within a
# column — the same lexicographic geometry as TargetingStrategy.dist, so attack targeting and
# effect targeting agree on what "nearest" means. Same half: plain Manhattan, scaled by the
# same factor so mixed ally/enemy pools stay commensurate.
#
# Kept bit-identical through the location refactor: it still reads two addresses, it just no
# longer reads them off the units.
static func board_distance(from: BoardLocation, to: BoardLocation) -> int:
	if from == null or to == null:
		return 1 << 30
	if to.side == from.side:
		return (absi(from.row - to.row) + absi(from.col - to.col)) * BoardData.ROWS
	var lane_offset: int = absi(from.row + to.row - (BoardData.ROWS - 1))
	var depth: int
	if from.side == 0:
		depth = BoardData.COLS + to.col - from.col
	else:
		depth = BoardData.COLS + from.col - to.col
	return depth * BoardData.ROWS + lane_offset
