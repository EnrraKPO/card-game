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

# THE "a unit just left play" moment — emitted by retire(), which every removal path funnels
# through (the presented death in the cascade's bury AND the board's silent effect-kill sweep).
# Anything owed for a death hangs off this one wire: combat pays kill bounties here. A COPY
# starts with no subscribers (signals don't copy), so a simulated death structurally cannot
# pay — the rewards_live flag below is the explicit policy on top of that structure.
signal unit_retired(inst: CardInstance)
# A dead unit swept by cleanup — the VIEW's cue to drop its card on the spot (the presented
# death path keeps the card standing for its dressing instead; see CombatCascade.bury).
signal unit_swept(inst: CardInstance)
# A unit the RULES put into play (a queued spawn payload, a hook's material spawn) — the
# view's cue to build its card. Board-driven placements don't emit this; their views exist.
signal unit_spawned(inst: CardInstance)

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


# Every unit on either grid, reading order (row-major, player cell before enemy cell) —
# moved verbatim from CombatBoard, which now forwards here: enumeration of the world is
# the world's own business.
func get_all_units() -> Array:
	var all: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if player_grid[r][c] != null:
				all.append(player_grid[r][c])
			if enemy_grid[r][c] != null:
				all.append(enemy_grid[r][c])
	return all


# THE activation order: who acts, and in what order, when the round resolves. Speed first,
# then the player's army, then depth (the unit furthest forward on its own side goes first),
# then the back row — every tie broken deterministically, because an arbitrary order between
# equal units reads as a rule to the player.
#
# This is the ONE definition. The round loop walks it to resolve the fight and the turn-order
# strip walks it to SHOW the fight's order (see TurnOrderStrip); a second copy of this sort
# anywhere is a promise the display can quietly break.
#
# It lists EVERY unit, including ones that will not swing (a tapped building spent its attack).
# Their turn still comes up — their activate moment fires, poison ticks, statuses decay — so the
# display shows them in place, greyed, rather than dropping them: a list that hid them would put
# a unit's neighbours at numbers the round never calls.
# WHOSE turn is being resolved right now — set by the round loop as it walks turn_order, null
# between rounds. A FACT the loop already knows, published rather than pushed at a display: the
# strip reads it to light the entry whose moment it is (see TurnOrderStrip), and reading it costs
# nothing, so the cue can track the fight frame by frame instead of on a poll.
var acting: CardInstance = null


func turn_order() -> Array:
	var order := get_all_units()
	order.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var sa := a.get_attribute("speed")
		var sb := b.get_attribute("speed")
		if sa != sb:
			return sa > sb
		if a.owner != b.owner:
			return a.owner < b.owner
		var pa: int = a.col if a.owner == 0 else BoardData.COLS - 1 - a.col
		var pb: int = b.col if b.owner == 0 else BoardData.COLS - 1 - b.col
		if pa != pb:
			return pa > pb
		return a.row > b.row
	)
	return order


# A unit leaves PLAY — state only, and instantly. Targeting, king checks and the next
# attacker stop seeing it the moment this returns; whoever is presenting the death disposes
# of its card afterwards (the view half stayed on CombatBoard). Emits unit_retired while
# any card view is still standing, so listeners may read where it stood.
func retire(inst: CardInstance) -> void:
	var grid: Array = player_grid if inst.owner == 0 else enemy_grid
	var grid_row: Array = grid[inst.row]
	grid_row[inst.col] = null
	unit_retired.emit(inst)


# The one context builder (moved from CombatBoard, which forwards here): grids + sides so
# side targets always resolve, the world's OWN modifier set for run-scope dispatch, and the
# world itself for board procedures (spawn payloads, CUSTOM hooks).
func make_context(src: CardInstance) -> EffectContext:
	var ctx := EffectContext.make(src, player_grid, enemy_grid)
	ctx.player_side = player_side
	ctx.enemy_side = enemy_side
	ctx.run_modifiers = modifiers
	ctx.world = self
	return ctx


# ── Placement & the play moment ────────────────────────────────────────────────────────

# The STATE of putting a unit at (r, c): position, allegiance, the grid write, and the
# composition-cache invalidation every owner change requires. View-silent — callers with a
# card view (board placements) manage it themselves; rules-driven arrivals use spawn_unit.
func place_unit(inst: CardInstance, r: int, c: int, p_owner: int) -> void:
	inst.row = r
	inst.col = c
	inst.owner = p_owner
	var grid: Array = grid_of(p_owner)
	var grid_row: Array = grid[r]
	grid_row[c] = inst
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach


# A rules-driven arrival: place + tell the view a card is owed (see unit_spawned).
func spawn_unit(inst: CardInstance, r: int, c: int, p_owner: int) -> void:
	place_unit(inst, r, c, p_owner)
	unit_spawned.emit(inst)


# THE play moment — a unit's ON_PLAY triggers, fired in this world's context (moved out of
# CombatBoard.place_*, so placement triggers run under a chosen world wherever it came
# from). Returns the results; presenting them is the caller's business (the live board
# hands them to combat, the spawn drain below discards them — both as before).
func play_dispatch(inst: CardInstance) -> Array:
	return EffectSystem.trigger(GameEvent.make(&"play", inst), inst, make_context(inst))


# ── Death sweep & effect-driven spawning (moved verbatim-in-shape from CombatBoard) ─────

# Units conjured by effects, pending placement. Queued rather than placed immediately so an
# on-death spawn resolves AFTER the corpse leaves the board; cleanup_deaths flushes.
var _pending_spawns: Array = []   # [{ "id": String, "count": int, "owner": int, "row": int, "col": int }]
var _flushing_spawns := false


func queue_spawn(card_id: String, count: int, anchor: CardInstance) -> void:
	_pending_spawns.append({"id": card_id, "count": maxi(1, count),
			"owner": anchor.owner, "row": anchor.row, "col": anchor.col})


# Sweeps effect-kills, then flushes queued effect spawns now that corpses have left their
# slots (an on-death split reclaims where its parent stood). A spawn fires ON_PLAY effects,
# which may kill units and queue further spawns — the loop drains it all; the guard keeps
# reentrant cleanup calls (from a spawn's own play trigger) from recursing into a second flush.
func cleanup_deaths() -> void:
	_sweep_dead()
	if _flushing_spawns:
		return
	_flushing_spawns = true
	while not _pending_spawns.is_empty():
		var s: Dictionary = _pending_spawns.pop_front()
		for _i in int(s["count"]):
			if not _spawn_from_queue(s):
				break   # that side's board is full — the surplus fizzles
		_sweep_dead()
	_flushing_spawns = false


func _sweep_dead() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardInstance = player_grid[r][c]
			if p != null and not p.is_alive():
				retire(p)
				unit_swept.emit(p)
			var e: CardInstance = enemy_grid[r][c]
			if e != null and not e.is_alive():
				retire(e)
				unit_swept.emit(e)


# Places one queued spawn into its anchor slot if free, else the nearest empty slot on that
# side. Fires the arrival's ON_PLAY effects like any other placement. False = side full.
func _spawn_from_queue(s: Dictionary) -> bool:
	var data := CardData.get_card(str(s["id"]))
	if data == null:
		push_error("CombatWorld: spawn payload names unknown card '%s'" % s["id"])
		return true   # a bad id is handled (loudly), not a full board
	var spawn_owner := int(s["owner"])
	var slot := _nearest_empty(spawn_owner, int(s["row"]), int(s["col"]))
	if slot.is_empty():
		return false
	var inst := CardInstance.from_data(data)
	inst.owner = spawn_owner
	Resolver.fill_health(inst)   # after owner is set, so run-wide unit bonuses fold in
	spawn_unit(inst, slot[0], slot[1], spawn_owner)
	play_dispatch(inst)   # results discarded, as the board always did for queued spawns
	return true


# The nearest empty slot to (row, col) on `spawn_owner`'s side by Manhattan distance (the
# anchor itself when free). [] = that side is full.
func _nearest_empty(spawn_owner: int, row: int, col: int) -> Array:
	var grid: Array = grid_of(spawn_owner)
	var best: Array = []
	var best_d := 999
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if grid[r][c] != null:
				continue
			var d := absi(r - row) + absi(c - col)
			if d < best_d:
				best_d = d
				best = [r, c]
	return best


# The complete snapshot: one identity remap spans grids and sides, so a unit referenced
# from several places (a hand spell's status source on a board unit, mutual killers) copies
# once and every reference converges on that one copy. Callers that need the identity
# table (the enemy engine maps candidates' live tokens into the copy) pass their own
# `remap` dictionary; the default is a fresh private one. LiveEffects' composition cache
# is keyed per instance — fresh copies simply miss it and compute lazily; no invalidation.
func copy(remap: Dictionary = {}) -> CombatWorld:
	var w := CombatWorld.new()
	w.player_grid = _copy_grid(player_grid, remap)
	w.enemy_grid = _copy_grid(enemy_grid, remap)
	w.player_side = player_side.copy(remap)
	w.enemy_side = enemy_side.copy(remap)
	w.modifiers = modifiers        # immutable environment — shared, never copied
	w.rewards_live = false         # a copy is a hypothetical: it never pays
	w._pending_spawns = _pending_spawns.duplicate(true)   # queued arrivals are combat state
	return w


static func _copy_grid(grid: Array, remap: Dictionary) -> Array:
	var out: Array = []
	for grid_row: Array in grid:
		var new_row: Array = []
		for cell: CardInstance in grid_row:
			new_row.append(CardInstance.copied(cell, remap))
		out.append(new_row)
	return out
