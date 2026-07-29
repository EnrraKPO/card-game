class_name CombatWorld
extends RefCounted

# THE cohesive context of combat rules state (COMBAT_DECOUPLING_REFACTOR.md Step 1): if the
# rules read it, it lives here — the two unit grids, the two resource sides, the run-level
# modifier set, and world policy. The cascade never scrapes an autoload, a global or a scene
# node for game state; copy() is therefore a COMPLETE snapshot, and a simulation that holds
# one holds everything a hypothetical can diverge on.
#
# Two tiers inside the one context, and copy() treats them differently:
#   • Mutable state (grids, cards, statuses, sides, policy flags) — deep-copied through one
#     shared identity remap (original -> copy), so every internal reference in the copy
#     resolves to a copy, never to a live object.
#   • Immutable environment (card/status/ability defs, the modifiers set — fixed for a
#     fight's duration; consumable spending is a live-only gesture) — shared by reference.
#
# Copies are FULL-FIDELITY (relics/upgrades proc in simulations — they change board
# outcomes). A future "blind CPU" policy is just a copy constructed with an empty modifiers
# ref; the mechanism allows it, nothing implements it today (aligned 2026-07-29).

var player_grid: Array = []   # [row][col] -> CardInstance or null
var enemy_grid:  Array = []   # [row][col] -> CardInstance or null
var player_side: CombatSide = null
var enemy_side:  CombatSide = null

# The run-level (relic/upgrade) effect collection — immutable environment, shared into
# copies. Today read globally as GameData.current_modifiers by run-level dispatch; Step 3
# re-points that read here.
var modifiers: ModifierSet = null

# World policy: does this world write RUN state (kill bounties paying gold/exp)? True for
# the live world, false for every copy — a hypothetical never pays. Bounty logic gates on
# this rather than presentation ever deciding (see plan §2.5: bounty is game logic).
var rewards_live: bool = true


static func make(p_modifiers: ModifierSet = null) -> CombatWorld:
	var w := CombatWorld.new()
	for _r in BoardData.ROWS:
		var prow: Array = []
		var erow: Array = []
		for _c in BoardData.COLS:
			prow.append(null)
			erow.append(null)
		w.player_grid.append(prow)
		w.enemy_grid.append(erow)
	w.player_side = CombatSide.make(0)
	w.enemy_side = CombatSide.make(1)
	w.modifiers = p_modifiers
	return w


func side(side_owner: int) -> CombatSide:
	return player_side if side_owner == 0 else enemy_side


func grid_of(side_owner: int) -> Array:
	return player_grid if side_owner == 0 else enemy_grid


# The complete snapshot: one identity remap spans grids and sides, so a unit referenced
# from several places (a hand spell's status source on a board unit, mutual killers) copies
# once and every reference converges on that one copy. LiveEffects' composition cache is
# keyed per instance — fresh copies simply miss it and compute lazily; no invalidation.
func copy() -> CombatWorld:
	var remap: Dictionary = {}
	var w := CombatWorld.new()
	w.player_grid = _copy_grid(player_grid, remap)
	w.enemy_grid = _copy_grid(enemy_grid, remap)
	w.player_side = player_side.copy(remap)
	w.enemy_side = enemy_side.copy(remap)
	w.modifiers = modifiers        # immutable environment — shared, never copied
	w.rewards_live = false         # a copy is a hypothetical: it never pays
	return w


static func _copy_grid(grid: Array, remap: Dictionary) -> Array:
	var out: Array = []
	for grid_row: Array in grid:
		var new_row: Array = []
		for cell: CardInstance in grid_row:
			new_row.append(CardInstance.copied(cell, remap))
		out.append(new_row)
	return out
