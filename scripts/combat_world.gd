class_name CombatWorld
extends RefCounted

# THE cohesive context of combat rules state (COMBAT_DECOUPLING_REFACTOR.md Step 1): if the
# rules read it, it lives here — placement, the two resource sides, the run-level modifier set,
# and world policy. The cascade never scrapes an autoload, a global or a scene node for game
# state; copy() is therefore a COMPLETE snapshot, and a simulation that holds one holds
# everything a hypothetical can diverge on.
#
# Two tiers inside the one context, and copy() treats them differently:
#   • Mutable state (placement, cards, statuses, sides, policy flags) — deep-copied through one
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

# ── PLACEMENT: the one authority ────────────────────────────────────────────────────────
# The sole container of board coordinates (LOCATION_MANAGER_DESIGN.md). Both layers live in
# it — the pieces (units) and the ground (slots) — and nothing anywhere else stores, derives
# or remembers where something is. It is a MEMBER of the world, deliberately, and never a
# global: simulations copy the whole world to try out plans, and a globally reachable manager
# would silently share placement between a hypothetical and the real board (§4.2).
var locations: LocationManager = LocationManager.new()

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
	w.player_side = CombatSide.make(0)
	w.enemy_side = CombatSide.make(1)
	w.modifiers = p_modifiers
	return w


func side(side_owner: int) -> CombatSide:
	return player_side if side_owner == 0 else enemy_side


# ── Asking the board ────────────────────────────────────────────────────────────────────
# Thin doors onto the façade, kept because the world is what every rules path already holds.
# The (side, row, col) forms mint an address and forward; they survive for the callers whose
# own vocabulary is still a pair of loop counters (a board sweep, a fixture), and every one
# of them hands a WHOLE address onward from there — nothing downstream ever takes a row and
# a column and has to find a half (LOCATION_MANAGER_DESIGN.md §2.6).

# Where a unit (or any dockable) stands. Null = not on the board, which is now an honest
# absence rather than a sentinel coordinate a caller has to recognise.
func location_of(dockable: Object) -> BoardLocation:
	return locations.location_of(dockable)


# The GROUND at an address — ALWAYS answers for a real cell (see SLOT_LAYER_DESIGN.md). Lazy
# allocation is an invisible detail: to every caller the ground simply exists.
func slot_at(slot_side: int, r: int, c: int) -> BoardSlot:
	return BoardFacade.slot_at(self, BoardLocation.at(slot_side, r, c))


# Read-only ground lookup for PRESENTATION: answers null for ground that was never touched,
# so a render pass over the whole board doesn't allocate 24 slots that carry nothing.
# Rules paths use slot_at (which always answers).
func peek_slot(slot_side: int, r: int, c: int) -> BoardSlot:
	return BoardFacade.peek_slot(self, BoardLocation.at(slot_side, r, c))


# The unit standing at a ground address right now. Null = empty cell or out-of-range address.
func unit_at(slot_side: int, r: int, c: int) -> CardInstance:
	return BoardFacade.unit_at(self, BoardLocation.at(slot_side, r, c))


# Slots that currently carry statuses, in fixed address order (side, then row, then col) —
# the ticking paths re-run in simulations, so the order is sorted into existence rather than
# trusted. Expired-but-unfiled statuses don't count as activity (pull validity — see
# StatusEngine.is_expired).
func active_slots() -> Array:
	return BoardFacade.active_slots(self)


# A side's units as the 2D grid the older rules paths still speak in — DERIVED, never stored.
# This is the forwarding §5.1 calls for: the shape survives so targeting strategies and the
# effect context read unchanged, while the only copy of the fact lives in the manager. The
# array is a snapshot: writing into it changes nothing, which is the point.
func grid_of(side_owner: int) -> Array:
	var out: Array = []
	for r in BoardData.ROWS:
		var grid_row: Array = []
		for c in BoardData.COLS:
			grid_row.append(BoardFacade.unit_at(self, BoardLocation.at(side_owner, r, c)))
		out.append(grid_row)
	return out


var player_grid: Array:
	get: return grid_of(0)
var enemy_grid: Array:
	get: return grid_of(1)


# TRANSITIONAL, and deliberately loud about it: dock everything a grid array describes onto
# this world's half. Callers that still hand grids around (the enemy engine's public entry,
# fixtures) used to build a world by ASSIGNING its arrays — which cannot work once the arrays
# are a reading rather than the store, and would fail silently, leaving an empty board that
# simulates beautifully and answers nothing. This is the honest version of that move, and it
# goes away with the grid-shaped signatures (LOCATION_MANAGER_DESIGN.md §5.2).
func adopt_grid(grid: Array, side_owner: int) -> void:
	for r in mini(grid.size(), BoardData.ROWS):
		var grid_row: Array = grid[r]
		for c in mini(grid_row.size(), BoardData.COLS):
			var inst: CardInstance = grid_row[c]
			if inst != null:
				place_unit(inst, r, c, side_owner)


# Every unit on either half, in the board's declared reading order (row-major, player cell
# before enemy cell at each address).
func get_all_units() -> Array:
	return BoardFacade.units(self)


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
	# Depth is a SPATIAL reading of where each unit stands, taken once here rather than
	# re-derived inside the comparator — the sort runs O(n log n) times and the board is the
	# authority being asked.
	var placed: Dictionary = {}
	for unit: CardInstance in order:
		placed[unit] = location_of(unit)
	order.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var sa := a.get_attribute("speed")
		var sb := b.get_attribute("speed")
		if sa != sb:
			return sa > sb
		if a.owner != b.owner:
			return a.owner < b.owner
		var la: BoardLocation = placed[a]
		var lb: BoardLocation = placed[b]
		var pa: int = la.col if la.side == 0 else BoardData.COLS - 1 - la.col
		var pb: int = lb.col if lb.side == 0 else BoardData.COLS - 1 - lb.col
		if pa != pb:
			return pa > pb
		return la.row > lb.row
	)
	return order


# A unit leaves PLAY — state only, and instantly. Targeting, king checks and the next
# attacker stop seeing it the moment this returns; whoever is presenting the death disposes
# of its card afterwards (the view half stayed on CombatBoard). Emits unit_retired while
# any card view is still standing, so listeners may read where it stood.
func retire(inst: CardInstance) -> void:
	locations.undock(inst)
	unit_retired.emit(inst)


# (The dispatch-context builder died with the effect layer, 2026-08-11 — the rebuilt
# dispatch reads this world directly; resolvers are pure functions over a passed-in world,
# TARGETING_DESIGN.md §3.)


# ── Placement & the play moment ────────────────────────────────────────────────────────

# The STATE of putting a unit at (r, c): the dock, allegiance, and the composition-cache
# invalidation every owner change requires. View-silent — callers with a card view (board
# placements) manage it themselves; rules-driven arrivals use spawn_unit.
#
# `p_owner` sets ALLEGIANCE and names the half being stood on. Those are two questions with
# one answer today; they are asked separately now, so the day they diverge (a charmed unit
# fighting from the enemy half) is a data change rather than a rewrite.
func place_unit(inst: CardInstance, r: int, c: int, p_owner: int) -> void:
	place_unit_at(inst, BoardLocation.at(p_owner, r, c), p_owner)


func place_unit_at(inst: CardInstance, loc: BoardLocation, p_owner: int) -> void:
	if loc == null:
		push_error("CombatWorld: refusing to place %s at no location" % inst)
		return
	inst.owner = p_owner
	locations.dock(inst, loc)


# A rules-driven arrival: place + tell the view a card is owed (see unit_spawned).
func spawn_unit(inst: CardInstance, r: int, c: int, p_owner: int) -> void:
	spawn_unit_at(inst, BoardLocation.at(p_owner, r, c), p_owner)


func spawn_unit_at(inst: CardInstance, loc: BoardLocation, p_owner: int) -> void:
	place_unit_at(inst, loc, p_owner)
	unit_spawned.emit(inst)


# THE play moment. EFFECT DISPATCH RAZED (2026-08-11): the old ON_PLAY dispatcher died
# with the effect layer, so a play currently triggers nothing. NEEDS: every card's arrival
# emits `played` through the one event pipeline (TARGETING_DESIGN.md §9 — one uniform act;
# spells are cards that don't stick to the board); results present at the caller.
func play_dispatch(_inst: CardInstance) -> Array:
	return []


# ── Death sweep & effect-driven spawning (moved verbatim-in-shape from CombatBoard) ─────

# Units conjured by effects, pending placement. Queued rather than placed immediately so an
# on-death spawn resolves AFTER the corpse leaves the board; cleanup_deaths flushes.
# `owner` is the arrival's ALLEGIANCE; `anchor` is WHERE it wants to land — the two travel
# separately because they are separate facts (§2.6).
var _pending_spawns: Array = []   # [{ "id": String, "count": int, "owner": int, "anchor": BoardLocation }]
var _flushing_spawns := false


func queue_spawn(card_id: String, count: int, anchor: CardInstance) -> void:
	_pending_spawns.append({"id": card_id, "count": maxi(1, count),
			"owner": anchor.owner, "anchor": location_of(anchor)})


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
	for unit: CardInstance in get_all_units():
		if not unit.is_alive():
			retire(unit)
			unit_swept.emit(unit)


# Places one queued spawn into its anchor slot if free, else the nearest empty slot on that
# side. Fires the arrival's ON_PLAY effects like any other placement. False = side full.
func _spawn_from_queue(s: Dictionary) -> bool:
	var data := CardData.get_card(str(s["id"]))
	if data == null:
		push_error("CombatWorld: spawn payload names unknown card '%s'" % s["id"])
		return true   # a bad id is handled (loudly), not a full board
	var spawn_owner := int(s["owner"])
	var anchor: BoardLocation = s["anchor"]
	if anchor == null:
		return false   # the anchor left the board before the queue drained — nowhere to land
	var landing := BoardFacade.nearest_empty(self, anchor, anchor.side)
	if landing == null:
		return false
	var inst := CardInstance.from_data(data)
	inst.owner = spawn_owner
	Arbitrator.fill_health(inst)   # after owner is set, so run-wide unit bonuses fold in
	spawn_unit_at(inst, landing, spawn_owner)
	play_dispatch(inst)   # results discarded, as the board always did for queued spawns
	return true


# The complete snapshot: one identity remap spans both board layers and the sides, so a unit
# referenced from several places (a hand spell's status source on a board unit, mutual
# killers) copies once and every reference converges on that one copy. Callers that need the
# identity table (the enemy engine maps candidates' live tokens into the copy) pass their own
# `remap` dictionary; the default is a fresh private one. LiveEffects' composition cache
# is keyed per instance — fresh copies simply miss it and compute lazily; no invalidation.
#
# PLACEMENT copies through that same table (LocationManager.copy), which is why no dockable
# carries a position of its own: there is one board to copy, and copying it moves everything.
func copy(remap: Dictionary = {}) -> CombatWorld:
	var w := CombatWorld.new()
	# Register a twin for every dockable BEFORE the placement copy, which resolves through the
	# table and refuses to guess at anything missing from it.
	for unit: CardInstance in get_all_units():
		CardInstance.copied(unit, remap)
	for slot: BoardSlot in locations.docked(BoardFacade.GROUND):
		var new_slot := BoardSlot.new()
		remap[slot] = new_slot
		for si: StatusInstance in slot.statuses:
			new_slot.statuses.append(StatusInstance.copied(si, new_slot, remap))
	w.locations = locations.copy(remap)
	w.player_side = player_side.copy(remap)
	w.enemy_side = enemy_side.copy(remap)
	w.modifiers = modifiers        # immutable environment — shared, never copied
	w.rewards_live = false         # a copy is a hypothetical: it never pays
	w._pending_spawns = _pending_spawns.duplicate(true)   # queued arrivals are combat state
	return w
