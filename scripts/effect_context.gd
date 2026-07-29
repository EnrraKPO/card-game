class_name EffectContext
extends RefCounted

var source: CardInstance                 # the HOLDER: the unit whose effect is being evaluated
var player_board: Array  # [row][col] -> CardInstance or null
var enemy_board: Array   # [row][col] -> CardInstance or null
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


# UI-flow extras for MANUAL_SLOT effects (material delivery): the picked slot (may be EMPTY —
# that's the spawn case) and the live board node, injected by SpellCaster so a CUSTOM hook can
# perform board procedures (spawning a unit). An interim bridge until placement rides the
# Resolver; both stay null in headless/AI flows, and hooks must null-check them.
var manual_slot: SlotUI = null
var board_node: CombatBoard = null
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
