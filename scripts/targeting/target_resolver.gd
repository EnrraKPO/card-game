class_name TargetResolver
extends RefCounted

# THE single-issue contract of the targeting layer (TARGETING_DESIGN.md §3, §12.1, signed
# ATTACK_SYSTEM_DESIGN.html): a target resolver answers ONE question — *what am I pointing
# to?* — as an array of GameEntities. Empty is literally empty; all other states derive.
# It does not act, does not know about payloads, and holds no state: every answer derives
# fresh from the passed-in world (the on-read current ruling — computed at the trigger
# moment and the interactive idle, never maintained).
#
# No candidate-enumeration, viability, or validity queries exist here (execution rejects
# on empty resolution instead — prohibit-non-ops enforced at the invocation, not the
# offer). Manual conduct (suspend/pick/cancel) joins the contract with the spell rebuild.
#
# Species are inner classes of this file (ONE file on purpose — the TriggerResolver
# precedent: constructing inner classes during other classes' static init hits the
# load-order landmine with separate files). Each species is narrow, per one real need;
# generality lives in this contract alone.
#
# Authoring (the native dictionary form): { "kind": "<species>", ...species params }.
# Anything else is refused loudly — no permissive default.

# The anchors: `holder` is the spatial anchor (whom "nearest" measures from) and `owner`
# the allegiance anchor, same sentinel contract as the trigger layer. The auto-attack
# species below never read `owner` — their candidate pool is the OPPOSITE HALF OF THE
# BOARD, a spatial reading preserved verbatim from the razed layer ("a grid is a half").
const OWNER_FROM_HOLDER := TriggerResolver.OWNER_FROM_HOLDER


# The one question. Pure over `world`: previews, hypotheticals and enemy simulations pass
# whatever world they are asking about. An empty array is a real answer ("nobody"), and
# execution rejects on it — never the resolver's concern.
func resolve(_world: CombatWorld, _holder: CardInstance,
		_owner: int = OWNER_FROM_HOLDER) -> Array[GameEntity]:
	return []


# Native (dictionary) authored form.
func to_dict() -> Dictionary:
	return {}


# The one authored form. Unknown kinds are refused loudly: the dead legacy language is
# not parsed, and no species is ever guessed.
static func parse(targets_value: Variant) -> TargetResolver:
	if not (targets_value is Dictionary):
		push_error("TargetResolver: '%s' is not the native targets form — refusing" % str(targets_value))
		return null
	var d := targets_value as Dictionary
	match str(d.get("kind", "")):
		"nearest":
			return Nearest.new()
	push_error("TargetResolver: unknown targets kind '%s' — refusing (no permissive default)" % str(d.get("kind", "")))
	return null


# ── The auto-attack preference ordering (shared by the attack species) ────────────────
# THE GAME RULE, not a distance (LOCATION_MANAGER_DESIGN.md §2.10), kept BIT-IDENTICAL
# through the demolition: column depth dominates — a target in a nearer column always
# beats any target in a farther one — and the mirrored lane offset only orders targets
# within the same column, facing lane first. This is the most playtested behaviour in
# the game; the rebuild was not permitted to nudge it.
static func attack_dist(from: BoardLocation, to: BoardLocation) -> int:
	if from == null or to == null:
		return 1 << 30
	var lane_offset: int = absi(from.row + to.row - (BoardData.ROWS - 1))
	var depth: int
	if from.side == 0:
		depth = BoardData.COLS + to.col - from.col
	else:
		depth = BoardData.COLS + from.col - to.col
	# lane_offset < ROWS, so scaling depth by ROWS makes the comparison lexicographic
	return depth * BoardData.ROWS + lane_offset


# Every unit on the half opposite the holder, nearest-first by the preference above, with
# the deterministic row-then-col tie-break (sort_custom is NOT stable, and an arbitrary
# pick between equally-near targets reads as a targeting rule to the player). A holder
# standing nowhere reaches nobody; an empty pool is a legal "no target".
static func opposite_half_by_preference(world: CombatWorld, holder: CardInstance) -> Array:
	var from := BoardFacade.location_of(world, holder)
	if from == null:
		return []
	var out: Array = []
	for unit: CardInstance in BoardFacade.units(world):
		var loc := BoardFacade.location_of(world, unit)
		if loc != null and loc.side != from.side:
			out.append(unit)
	out.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var la := BoardFacade.location_of(world, a)
		var lb := BoardFacade.location_of(world, b)
		var da := attack_dist(from, la)
		var db := attack_dist(from, lb)
		if da != db:
			return da < db
		if la.row != lb.row:
			return la.row < lb.row
		return la.col < lb.col
	)
	return out


# ── Species ──────────────────────────────────────────────────────────────────────────

class Nearest extends TargetResolver:
	# The geometrically closest enemy under the preference ordering. Resolves to at most
	# ONE unit — the head of the preference order.
	func resolve(world: CombatWorld, holder: CardInstance,
			_owner: int = TargetResolver.OWNER_FROM_HOLDER) -> Array[GameEntity]:
		var out: Array[GameEntity] = []
		var pool := TargetResolver.opposite_half_by_preference(world, holder)
		if not pool.is_empty():
			out.append(pool[0] as GameEntity)
		return out

	func to_dict() -> Dictionary:
		return {"kind": "nearest"}
