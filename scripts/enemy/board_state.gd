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

# The player's unspent mana at planning time. Open mana is potential damage the player can
# still convert this round (a fresh unit, a spell), so scoring folds it into the threat
# mass at BoardScoring.MANA_THREAT_RATE. Snapshot data like everything else here — the
# engine never spends or mutates it.
var player_mana: int = 0

# The CPU's own mana story this turn, for the mana-optimization criterion: the turn's
# whole budget, what is left after the plays this state already includes, and the mana
# costs of the cards still in the CPU's hand/pool (for the spendability subset-sum).
# Stamped by the ENGINE (capture can't know them); states scored outside a planning turn
# leave total at 0 and the criterion reads as a constant.
var enemy_mana_total: int = 0
var enemy_mana_left: int = 0
var hand_costs: Array = []

# The mana costs of the PLACEABLE units still in hand — the idle-hand criterion's whole
# input (user mandate 2026-07-30: a unit the CPU can field must never sit in hand). A
# subset of hand_costs: spells and kings are excluded, because neither can be placed and
# holding one is not withholding a body. Stamped and maintained by the ENGINE alongside
# hand_costs.
var hand_unit_costs: Array = []

# The mana the CPU had when THIS PICK began — the yardstick the idle-hand charge judges
# affordability against, and the reason it cannot be dodged. Measured against the mana a
# candidate has LEFT, any play that drains the pool would make the withheld body read as
# unaffordable and the charge would evaporate: casting a spell would "excuse" keeping a
# unit in hand. Judged against the pre-choice budget, spending the mana elsewhere keeps
# the charge, and only actually FIELDING the body pays it off. Stamped by the engine onto
# every entry of a pick's cohort, exactly like mana_capacity_before; a state scored outside
# a planning turn leaves it 0 and the criterion goes silent.
var hand_budget_before: int = 0

# Mana spent by the ACTION that produced this state, within the pick being scored — the
# mana criterion is a property of the CHOICE, not of the turn so far (user 2026-07-30):
# a choice that spends nothing expresses nothing, however healthy the budget looks. The
# engine zeroes this on the do-nothing baseline each pick and stamps each candidate's
# cost onto its own result.
var mana_spent_step: int = 0

# The most mana ANY line of play could still have consumed from the position this pick
# started in — the yardstick the mana criterion measures a choice against (waste is only
# waste if a better line existed). Stamped by the engine onto every candidate of a pick.
var mana_capacity_before: int = 0

# ── The valuation pass's stamp (BoardScoring.run_valuation, user-designed 2026-07-30) ──
# The signed total worth of the battlefield (own units positive, player units negative)
# and whether the pass has run on THIS state. DERIVED data, deliberately NOT carried by
# copy() or the capture seams (unlike the engine-stamped mana story above): a copy exists
# to be mutated, so a carried stamp would be a stale lie — every mutation path hands the
# scorer an unvalued state and the pass re-runs. Per-unit results live on UnitState
# (raw_value / persistence / value), same rule.
var value_total: float = 0.0
var valued: bool = false
# WHO priced it — the personality the pass ran with (null = the global config). The stamp
# is only canon for the scorer whose pricer produced it: the same state read by a scorer
# with a DIFFERENT price list must be re-valued, or one fight's prices leak into another's
# reading (caught live: a probe compared a state priced without a per-fight unit bonus
# against candidates priced with it, and the baseline read six points poor).
var valued_by: EnemyPersonality = null

# Units that DIED during this simulation (the apply seam records them off the swept grid).
# They exist because a board is not a complete account of what a candidate did: every
# negative criterion sums over living units, so a unit that simply vanished would take its
# own risk term with it and make "destroy your own valuable unit" read as relief. The
# corpses stay visible to scoring and invisible to geometry — which is exactly the split
# reality has. Always empty on capture: it records what THIS decision's simulation cost.
var graveyard: Array = []


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
	# How many of the card's own effects are event-driven vs standing — captured as COUNTS
	# because the board-value criterion prices them by category (BoardValueConfig), never
	# interprets them. ON_PLAY effects are excluded: a fielded unit's battlecry already
	# fired. Status-borne effects are deliberately not counted (temporary by nature; their
	# stat side already folds into the captured stats at read time).
	var triggered_effects: int = 0
	var live_effects: int = 0
	# The valuation pass's per-unit stamp (BoardScoring.run_valuation): what the unit IS
	# (raw_value, current health irrelevant), how likely it survives the turn
	# (persistence, 0..1), and the canon worth every value eval reads (value = raw ×
	# persistence-dialed discount). Derived — meaningful only on a state whose `valued`
	# flag is set; deliberately not copied (see BoardState.value_total).
	var raw_value: float = 0.0
	var persistence: float = 1.0
	var value: float = 0.0

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
		for e: Effect in inst.data.effects:
			if e.trigger == Effect.Trigger.ON_PLAY:
				continue
			if e.kind == Effect.Kind.MODIFIER or e.kind == Effect.Kind.INTERCEPTOR:
				u.live_effects += 1
			else:
				u.triggered_effects += 1
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
		u.triggered_effects = triggered_effects
		u.live_effects = live_effects
		return u


# Snapshots the live grids ([row][col] -> CardInstance or null). Takes plain grids, not
# the CombatBoard control — the engine never sees a scene node.
static func capture(live_player_grid: Array, live_enemy_grid: Array,
		p_player_mana: int = 0) -> BoardState:
	var s := BoardState.new()
	s.player_units = _capture_grid(live_player_grid)
	s.enemy_units = _capture_grid(live_enemy_grid)
	s.player_mana = p_player_mana
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
	s.player_mana = player_mana
	s.enemy_mana_total = enemy_mana_total
	s.enemy_mana_left = enemy_mana_left
	s.hand_costs = hand_costs.duplicate()
	s.hand_unit_costs = hand_unit_costs.duplicate()
	s.hand_budget_before = hand_budget_before
	s.mana_spent_step = mana_spent_step
	s.mana_capacity_before = mana_capacity_before
	# A fresh list of the same corpses: nothing ever mutates a dead unit, so the entries
	# are shared while the LIST stays per-copy (appending to one never reaches another).
	s.graveyard = graveyard.duplicate()
	# value_total / valued are DELIBERATELY not carried (nor UnitState's value stamp): a
	# copy exists to be mutated, and the valuation pass re-runs on unvalued states. This
	# is the one exception to the "every stamped field goes in three places" rule —
	# because it is derived, not engine-stamped.
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
