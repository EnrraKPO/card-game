class_name EffectContext
extends RefCounted

var source: CardInstance                 # the HOLDER: the unit whose effect is being evaluated

# The two halves as the 2D grids the older targeting paths still speak in. DERIVED from the
# world whenever there is one, so a dispatch always reads the board as it stands RIGHT NOW —
# a unit killed earlier in the same cascade is gone from the very next read, exactly as it was
# when these fields aliased the world's live arrays. Placement has one home (see
# LocationManager) and a context that snapshotted it would be a second, quietly out of date.
# The stored arrays behind them serve contexts built with no world (tests, non-combat
# dispatch), which pass their boards in directly.
var _player_board: Array = []
var _enemy_board: Array = []
var player_board: Array:   # [row][col] -> CardInstance or null
	get: return world.grid_of(0) if world != null else _player_board
	set(v): _player_board = v
var enemy_board: Array:    # [row][col] -> CardInstance or null
	get: return world.grid_of(1) if world != null else _enemy_board
	set(v): _enemy_board = v
var manual_target: CardInstance = null
var attack_target: CardInstance = null   # the unit `source` is striking, during an ON_ATTACK
var attacker: CardInstance = null        # the unit that dealt the blow, during an ON_DAMAGE_TAKEN
# The SUBJECT: the unit the broadcast event is about (who activated / attacked / died). An effect's
# subject_filter is evaluated against this relative to the holder; null for subject-less phase events.
var subject: CardInstance = null
# The allegiance anchor for target resolution — the side that "ally"/"enemy" read relative to.
# Left at the sentinel for board effects (targeting anchors on the holder's own side); set to
# the PLAYER side (0) for run-scope dispatch (relics/upgrades have no holder unit, so their
# targeting anchors on the player regardless of whose event fired). See TargetResolver._anchor.
var owner_anchor: int = -9999   # == TriggerResolver.OWNER_FROM_HOLDER


# The picked SLOT for MANUAL_SLOT effects (material delivery) as plain coordinates — the
# gesture edge (SpellCaster) translates its SlotUI into these; the slot may be EMPTY (that's
# the spawn case). -1 = no slot picked; hooks must check.
var manual_row: int = -1
var manual_col: int = -1
# WHERE this effect is anchored, AS A LOCATION — the coordinate-provider channel for
# position-first targeting (the AT_LOCATION kind reads these; see SLOT_LAYER_DESIGN.md).
# Set ONLY by ground-layer dispatch (a slot status firing: the slot's own address); unit
# dispatches never set it — their anchor is `source`, a unit. Three plain ints mirroring
# manual_row/col: no position object, no slot reference in the context. -1 = no anchor.
var anchor_side: int = -1
var anchor_row: int = -1
var anchor_col: int = -1
# The cohesive combat world this dispatch runs in (grids, sides, spawn queue — see
# CombatWorld), set by CombatWorld.make_context. Null in contexts built outside a combat,
# where board procedures (spawn payloads, hooks) are inert.
var world: CombatWorld = null
# The activated ability being resolved, when this dispatch is an ability activation — how
# hooks read the ability's parameters (e.g. deliver_material's material key). Null otherwise.
var ability: AbilityData = null
# The specific Effect currently being applied, so a CUSTOM hook can read PER-EFFECT
# parameters (e.g. deliver_material's per-effect `material` override). Set by EffectSystem
# immediately before the hook runs; null outside CUSTOM dispatch.
var effect: Effect = null

# The two CombatSides, for side-targeted effects ("draw 2" — see TargetResolver.Side).
# Injected wherever a combat is live (CombatBoard.make_context); null in contexts built
# outside one, where a side target simply resolves to nothing.
var player_side: CombatSide = null
var enemy_side: CombatSide = null

# The run-level (relic/upgrade) effect collection run-scope dispatch fires from — THE context
# read replacing EffectSystem's old ambient GameData.current_modifiers reads (world amendment,
# COMBAT_DECOUPLING_REFACTOR.md Step 1/3): a simulated world hands its own set through here.
# make() defaults it to the live run set, so the ambient read is confined to context
# CONSTRUCTION; CombatWorld.make_context overrides it with the world's own reference.
var run_modifiers: ModifierSet = null


func side_for(side_owner: int) -> CombatSide:
	if side_owner == 0:
		return player_side
	if side_owner == 1:
		return enemy_side
	return null


static func make(src: CardInstance, p_board: Array, e_board: Array) -> EffectContext:
	var ctx := EffectContext.new()
	ctx.source = src
	ctx.player_board = p_board
	ctx.enemy_board = e_board
	ctx.run_modifiers = GameData.current_modifiers
	return ctx
