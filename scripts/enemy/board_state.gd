class_name BoardState
extends RefCounted

# The enemy engine's view of the battlefield: PLAIN COPYABLE DATA, no scene nodes and no
# live game objects (ENCOUNTER_ENGINE_DESIGN.md Part 5 — the one piece that must not be
# faked). The engine simulates candidate moves on copies of this, so a simulation can
# never touch real combat state.
#
# Each cell holds a UnitState — copied stat VALUES, not the live CardInstance. The one
# live reference a UnitState keeps is `source`, used purely as an identity token to map
# a chosen candidate back to an executable action; nothing in the engine reads or writes
# through it.

# Grids mirror CombatBoard's: [row][col] -> UnitState or null.
var player_units: Array = []
var enemy_units: Array = []


class UnitState:
	extends RefCounted

	var source: CardInstance = null   # identity token only — never dereferenced for state
	var card_id: String = ""
	var owner: int = -1               # 0 = player, 1 = enemy (CardInstance.owner axis)
	var row: int = -1
	var col: int = -1
	var is_king: bool = false
	var is_building: bool = false
	var role: String = ""   # battlefield-role tag (CardData.role); "" = untagged
	var cost: int = 0
	var attack: int = 0
	var health: int = 0
	var max_health: int = 0
	var shield: int = 0
	var speed: int = 0
	var strikes: int = 1
	# The unit's activated-ability ids (CardData.ability_ids) and whether its tap is spent
	# (attack_exhausted) — what the ability candidate generator needs to gate legality.
	var ability_ids: Array = []
	var exhausted: bool = false

	static func from_instance(inst: CardInstance) -> UnitState:
		var u := UnitState.new()
		u.source = inst
		u.card_id = inst.data.id
		u.owner = inst.owner
		u.row = inst.row
		u.col = inst.col
		u.is_king = inst.data.is_king
		u.is_building = inst.data.is_building()
		u.role = inst.data.role
		u.cost = inst.get_attribute("cost")
		u.attack = inst.get_attribute("attack")
		u.health = inst.current_health
		u.max_health = inst.get_attribute("max_health")
		u.shield = inst.current_shield
		u.speed = inst.get_attribute("speed")
		u.strikes = inst.get_attribute("strikes")
		u.ability_ids = inst.data.ability_ids().duplicate()
		u.exhausted = inst.attack_exhausted
		return u

	func copy() -> UnitState:
		var u := UnitState.new()
		u.source = source
		u.card_id = card_id
		u.owner = owner
		u.row = row
		u.col = col
		u.is_king = is_king
		u.is_building = is_building
		u.role = role
		u.cost = cost
		u.attack = attack
		u.health = health
		u.max_health = max_health
		u.shield = shield
		u.speed = speed
		u.strikes = strikes
		u.ability_ids = ability_ids.duplicate()
		u.exhausted = exhausted
		return u


# Snapshots the live grids ([row][col] -> CardInstance or null). Takes plain grids, not
# the CombatBoard control — the engine never sees a scene node.
static func capture(live_player_grid: Array, live_enemy_grid: Array) -> BoardState:
	var s := BoardState.new()
	s.player_units = _capture_grid(live_player_grid)
	s.enemy_units = _capture_grid(live_enemy_grid)
	return s


static func _capture_grid(live_grid: Array) -> Array:
	var grid: Array = []
	for r in BoardData.ROWS:
		var row: Array = []
		for c in BoardData.COLS:
			var inst: CardInstance = live_grid[r][c]
			row.append(UnitState.from_instance(inst) if inst != null else null)
		grid.append(row)
	return grid


static func empty() -> BoardState:
	var s := BoardState.new()
	s.player_units = _blank_grid()
	s.enemy_units = _blank_grid()
	return s


static func _blank_grid() -> Array:
	var grid: Array = []
	for _r in BoardData.ROWS:
		var row: Array = []
		for _c in BoardData.COLS:
			row.append(null)
		grid.append(row)
	return grid


# Deep copy: fresh grids, fresh UnitStates. Mutating the copy can never reach the original.
func copy() -> BoardState:
	var s := BoardState.new()
	s.player_units = _copy_grid(player_units)
	s.enemy_units = _copy_grid(enemy_units)
	return s


static func _copy_grid(grid: Array) -> Array:
	var out: Array = []
	for r in BoardData.ROWS:
		var row: Array = []
		for c in BoardData.COLS:
			var u: UnitState = grid[r][c]
			row.append(u.copy() if u != null else null)
		out.append(row)
	return out


# ── Queries ────────────────────────────────────────────────────────────────────────

func grid_of(side: int) -> Array:
	return player_units if side == 0 else enemy_units


func unit_at(side: int, r: int, c: int) -> UnitState:
	return grid_of(side)[r][c]


func units(side: int) -> Array:
	var out: Array = []
	for row: Array in grid_of(side):
		for cell in row:
			if cell != null:
				out.append(cell)
	return out


# The unit standing for this identity token, on either side — how a candidate's
# CardInstance reference is resolved inside a simulated copy. Null when not fielded.
func find(p_source: CardInstance) -> UnitState:
	for side in 2:
		for u: UnitState in units(side):
			if u.source == p_source:
				return u
	return null


# The side's king unit, or null when it isn't on the board.
func captain(side: int) -> UnitState:
	for u: UnitState in units(side):
		if u.is_king:
			return u
	return null


# Empty slots as [row, col] pairs (the codebase's slot convention).
func empty_slots(side: int) -> Array:
	var out: Array = []
	var grid := grid_of(side)
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if grid[r][c] == null:
				out.append([r, c])
	return out


# ── Mutation (called by the apply seam on COPIES only) ─────────────────────────────

func place(u: UnitState, r: int, c: int) -> void:
	u.row = r
	u.col = c
	grid_of(u.owner)[r][c] = u
