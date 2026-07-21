class_name CombatBoard
extends Node

# Emitted when a player unit is placed; combat handles mana deduction + animation.
signal unit_placed(inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, on_play_results: Array)
# Emitted for any slot press; combat and spell_caster both listen.
signal slot_pressed(slot: SlotUI)
# Emitted when a spell is drag-dropped onto a slot; spell_caster handles.
signal spell_dropped(slot: SlotUI, card_ui: CardUI)
# Emitted when a fielded unit with an armed autocast ability is dropped onto a valid occupied
# slot (the drop already passed `can_autocast` via SlotUI.autocast_check); combat routes it
# to SpellCaster.activate_autocast. The dragged unit never moves.
signal autocast_dropped(slot: SlotUI, card_ui: CardUI)

var player_grid: Array = []   # [row][col] -> CardInstance or null
var enemy_grid:  Array = []   # [row][col] -> CardInstance or null
var player_slots: Array = []  # [row][col] -> SlotUI
var enemy_slots:  Array = []  # [row][col] -> SlotUI

# Set by the orchestrator during setup.
var placement_enabled: bool  = false
var is_hand_card: Callable        # func(CardUI) -> bool
var get_mana: Callable            # func() -> int
# Whether dropping this dragged unit onto this slot fires its armed autocast ability —
# SpellCaster.autocast_drop_ok (armed + payable + eligible occupant), injected like get_mana.
var can_autocast: Callable        # func(CardInstance, SlotUI) -> bool
# The two CombatSides (player resources), injected by combat so every effect context built
# during a fight can resolve side targets ("draw 2" — see TargetResolver.Side).
var player_side: CombatSide = null
var enemy_side: CombatSide = null
var _default_strategy := TargetingNearest.new()


# The one context builder for live-combat effect dispatch: grids + the sides. Every
# in-combat EffectContext comes through here so a side target is never silently missing.
func make_context(src: CardInstance) -> EffectContext:
	var ctx := EffectContext.make(src, player_grid, enemy_grid)
	ctx.player_side = player_side
	ctx.enemy_side = enemy_side
	# Board access rides every in-combat context (spawn payloads queue through it; CUSTOM
	# hooks board-procedure through it). SpellCaster's own injection becomes redundant but
	# harmless — this is the one context builder, so nothing in combat can miss it.
	ctx.board_node = self
	return ctx

# Zone dressing: each half sits on its own faintly tinted field so "my side / their side" reads
# at a glance — cool blue for the player, warm red for the enemy. Low alpha keeps the shared
# backdrop showing through.
const HALF_PAD := 8.0   # inner inset between a zone's edge and its slot grid (combat's
						 # _resize_board budgets for it — keep the two in sync)
const PLAYER_ZONE_BG := Color(0.36, 0.48, 0.78, 0.28)
const ENEMY_ZONE_BG  := Color(0.72, 0.36, 0.42, 0.24)


# ── Initialisation ─────────────────────────────────────────────────────────────

func setup_grids() -> void:
	for r in BoardData.ROWS:
		player_grid.append([])
		enemy_grid.append([])
		player_slots.append([])
		enemy_slots.append([])
		for _c in BoardData.COLS:
			player_grid[r].append(null)
			enemy_grid[r].append(null)
			player_slots[r].append(null)
			enemy_slots[r].append(null)


func build_section(parent: BoxContainer, is_player: bool) -> void:
	# A board half: a tinted zone panel (see the ZONE_BG consts) holding the slot grid, centred
	# in whatever area it's given so leftover space (after combat sizes the slots to fill) sits
	# as balanced margins rather than a lopsided gap. No "Player"/"Enemy" label — the tints and
	# the near/far halves read for themselves and a label only stole vertical room.
	var zone := Panel.new()
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zone.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	var zone_style := StyleBoxFlat.new()
	zone_style.bg_color = PLAYER_ZONE_BG if is_player else ENEMY_ZONE_BG
	zone_style.set_corner_radius_all(12)
	zone.add_theme_stylebox_override("panel", zone_style)
	parent.add_child(zone)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", int(HALF_PAD))
	pad.add_theme_constant_override("margin_right", int(HALF_PAD))
	pad.add_theme_constant_override("margin_top", int(HALF_PAD))
	pad.add_theme_constant_override("margin_bottom", int(HALF_PAD))
	zone.add_child(pad)

	var center := CenterContainer.new()
	pad.add_child(center)

	var grid := GridContainer.new()
	grid.columns = BoardData.COLS
	grid.add_theme_constant_override("h_separation", BoardData.SLOT_GAP)
	grid.add_theme_constant_override("v_separation", BoardData.SLOT_GAP)
	center.add_child(grid)

	var row_order: Array = range(BoardData.ROWS) if is_player \
		else range(BoardData.ROWS - 1, -1, -1)

	for r in row_order:
		for c in BoardData.COLS:
			var slot := SlotUI.new()
			slot.row      = r
			slot.col      = c
			slot.owner_id = 0 if is_player else 1

			if is_player:
				player_slots[r][c]   = slot
				slot.accept_check    = _can_drop_on_player_slot
				slot.autocast_check  = _can_autocast_on_slot
				var s := slot
				s.card_dropped.connect(func(cu: CardUI): _on_player_slot_dropped(s, cu))
				s.pressed.connect(func(): slot_pressed.emit(s))
			else:
				enemy_slots[r][c] = slot
				var s := slot
				s.card_dropped.connect(func(cu: CardUI): _on_enemy_slot_dropped(s, cu))
				s.pressed.connect(func(): slot_pressed.emit(s))

			grid.add_child(slot)


func place_kings(player_king_id: String = "king", enemy_king_id: String = "king",
		enemy_power: float = 0.0) -> void:
	var back: int = BoardData.ROWS - 1

	var pk := CardInstance.from_data(CardData.get_card(player_king_id))
	pk.row = back; pk.col = 0; pk.owner = 0
	player_grid[back][0] = pk
	var pk_ui := CardUI.create(pk)
	player_slots[back][0].set_card(pk_ui)
	_wire_unit_drag(pk_ui)

	# The enemy Captain scales with encounter power, like the rest of the deck.
	var ek := CardInstance.from_data(CardData.scaled(CardData.get_card(enemy_king_id), enemy_power))
	ek.row = back; ek.col = BoardData.COLS - 1; ek.owner = 1
	enemy_grid[back][BoardData.COLS - 1] = ek
	enemy_slots[back][BoardData.COLS - 1].set_card(CardUI.create(ek))
	LiveEffects.invalidate_compositions()   # owners set — allegiance-gated grants may now reach


# ── Card operations ────────────────────────────────────────────────────────────

func can_place_from_hand(card_ui: CardUI) -> bool:
	if card_ui.card_instance.is_spell:
		return false
	return card_ui.card_instance.get_attribute("cost") <= get_mana.call()


func place_enemy_card(inst: CardInstance, r: int, c: int) -> Array:
	inst.row = r; inst.col = c; inst.owner = 1
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach
	enemy_grid[r][c] = inst
	var ui := CardUI.create(inst)
	enemy_slots[r][c].set_card(ui)
	var results := EffectSystem.trigger(
		GameEvent.make(&"play", inst), inst, make_context(inst))
	cleanup_effect_deaths()
	refresh()
	return results


# Spawns a unit into an empty PLAYER slot outside the hand-placement flow (material
# delivery's empty-slot case — see EffectHooks.deliver_material). Mirrors place_enemy_card:
# occupies the grid, creates the CardUI, fires the unit's ON_PLAY effects.
func spawn_player_card(inst: CardInstance, r: int, c: int) -> Array:
	if player_grid[r][c] != null:
		return []
	inst.row = r; inst.col = c; inst.owner = 0
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach
	player_grid[r][c] = inst
	var ui := CardUI.create(inst)
	(player_slots[r][c] as SlotUI).set_card(ui)
	_wire_unit_drag(ui)
	var results := EffectSystem.trigger(
		GameEvent.make(&"play", inst), inst, make_context(inst))
	cleanup_effect_deaths()
	refresh()
	return results


# Relocates an already-placed enemy unit to an empty slot (the CPU's reposition
# action). Carries the existing CardUI across so no ON_PLAY re-triggers.
func move_enemy_card(inst: CardInstance, r: int, c: int) -> void:
	var ui: CardUI = (enemy_slots[inst.row][inst.col] as SlotUI).clear_card()
	enemy_grid[inst.row][inst.col] = null
	inst.row = r; inst.col = c
	enemy_grid[r][c] = inst
	(enemy_slots[r][c] as SlotUI).set_card(ui)


func remove_card(inst: CardInstance) -> void:
	var slots := player_slots if inst.owner == 0 else enemy_slots
	var board := player_grid  if inst.owner == 0 else enemy_grid
	var card_ui: CardUI = (slots[inst.row][inst.col] as SlotUI).clear_card()
	board[inst.row][inst.col] = null
	if card_ui:
		card_ui.queue_free()


func get_card_ui(inst: CardInstance) -> CardUI:
	if inst.owner == 0:
		return (player_slots[inst.row][inst.col] as SlotUI).get_card()
	return (enemy_slots[inst.row][inst.col] as SlotUI).get_card()


func get_all_units() -> Array:
	var all: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if player_grid[r][c] != null:
				all.append(player_grid[r][c])
			if enemy_grid[r][c] != null:
				all.append(enemy_grid[r][c])
	return all


func find_target(attacker: CardInstance) -> CardInstance:
	var target_board: Array = enemy_grid if attacker.owner == 0 else player_grid
	var strategy: TargetingStrategy = attacker.data.targeting_strategy \
		if attacker.data != null else _default_strategy
	return strategy.find_target(attacker, target_board)


func any_king_dead() -> bool:
	var p_alive := false
	var e_alive := false
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if player_grid[r][c] != null and player_grid[r][c].data.is_king:
				p_alive = true
			if enemy_grid[r][c] != null and enemy_grid[r][c].data.is_king:
				e_alive = true
	return not p_alive or not e_alive


func get_player_king() -> CardInstance:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardInstance = player_grid[r][c]
			if p != null and p.data.is_king:
				return p
	return null


func player_king_alive() -> bool:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if player_grid[r][c] != null and player_grid[r][c].data.is_king:
				return true
	return false


func cleanup_effect_deaths() -> void:
	_sweep_dead()
	# Flush queued effect spawns now that corpses have left their slots (an on-death split
	# reclaims where its parent stood). A spawn fires ON_PLAY effects, which may kill units
	# and queue further spawns — the loop drains it all; the guard keeps reentrant cleanup
	# calls (from a spawn's own play trigger) from recursing into a second flush.
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
				remove_card(p)
			var e: CardInstance = enemy_grid[r][c]
			if e != null and not e.is_alive():
				remove_card(e)


# ── Effect-driven spawning (the `spawn` payload — see EffectSystem._apply) ─────

# Units conjured by effects, pending placement. Queued rather than placed immediately so an
# on-death spawn resolves AFTER the corpse leaves the board; cleanup_effect_deaths flushes.
var _pending_spawns: Array = []   # [{ "id": String, "count": int, "owner": int, "row": int, "col": int }]
var _flushing_spawns := false


func queue_spawn(card_id: String, count: int, anchor: CardInstance) -> void:
	_pending_spawns.append({"id": card_id, "count": maxi(1, count),
			"owner": anchor.owner, "row": anchor.row, "col": anchor.col})


# Places one queued spawn into its anchor slot if free, else the nearest empty slot on that
# side. Fires the arrival's ON_PLAY effects like any other placement. False = side full.
func _spawn_from_queue(s: Dictionary) -> bool:
	var data := CardData.get_card(str(s["id"]))
	if data == null:
		push_error("CombatBoard: spawn payload names unknown card '%s'" % s["id"])
		return true   # a bad id is handled (loudly), not a full board
	var owner := int(s["owner"])
	var slot := _nearest_empty(owner, int(s["row"]), int(s["col"]))
	if slot.is_empty():
		return false
	var inst := CardInstance.from_data(data)
	inst.owner = owner
	Resolver.fill_health(inst)   # after owner is set, so run-wide unit bonuses fold in
	inst.row = slot[0]; inst.col = slot[1]
	var grid: Array = player_grid if owner == 0 else enemy_grid
	var slots: Array = player_slots if owner == 0 else enemy_slots
	grid[slot[0]][slot[1]] = inst
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach
	var ui := CardUI.create(inst)
	(slots[slot[0]][slot[1]] as SlotUI).set_card(ui)
	if owner == 0:
		_wire_unit_drag(ui)
	Vfx.play("summon_materialize", ui)
	EffectSystem.trigger(GameEvent.make(&"play", inst), inst, make_context(inst))
	refresh()
	return true


# The nearest empty slot to (row, col) on `owner`'s side by Manhattan distance (the anchor
# itself when free). [] = that side is full.
func _nearest_empty(owner: int, row: int, col: int) -> Array:
	var grid: Array = player_grid if owner == 0 else enemy_grid
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


func refresh() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (player_slots[r][c] as SlotUI).get_card()
			if p:
				p.refresh()
			var e: CardUI = (enemy_slots[r][c] as SlotUI).get_card()
			if e:
				e.refresh()


# `eligible` (optional, func(CardInstance) -> bool) narrows targeting to slots whose occupant
# passes — used by spell targeting so only valid picks light up and accept drops (e.g. Castling
# can't target a unit that already has a Barrier). Without it, every slot toggles as before.
func set_slots_targetable(enabled: bool, eligible: Callable = Callable()) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			_set_slot_targetable(player_slots[r][c] as SlotUI, player_grid[r][c] as CardInstance, enabled, eligible)
			_set_slot_targetable(enemy_slots[r][c] as SlotUI, enemy_grid[r][c] as CardInstance, enabled, eligible)


func _set_slot_targetable(slot: SlotUI, occupant: CardInstance, enabled: bool, eligible: Callable) -> void:
	if not enabled or not eligible.is_valid():
		slot.set_targetable(enabled)
		return
	slot.set_targetable(occupant != null and bool(eligible.call(occupant)))


# Slot-level variant for MANUAL_SLOT effects (material delivery): `eligible` judges the SLOT
# itself — side, emptiness, occupant — so EMPTY slots can be valid picks (the spawn case),
# which the occupant-based filter above can never express.
func set_slots_targetable_by_slot(enabled: bool, eligible: Callable) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var ps := player_slots[r][c] as SlotUI
			var es := enemy_slots[r][c] as SlotUI
			ps.set_targetable(enabled and bool(eligible.call(ps)))
			es.set_targetable(enabled and bool(eligible.call(es)))


func set_board_card_filters(enabled: bool) -> void:
	var filter := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (player_slots[r][c] as SlotUI).get_card()
			if p:
				p.mouse_filter = filter
			var e: CardUI = (enemy_slots[r][c] as SlotUI).get_card()
			if e:
				e.mouse_filter = filter


# ── Internal drop handlers ─────────────────────────────────────────────────────

func _can_drop_on_player_slot(card_ui: CardUI, _slot: SlotUI) -> bool:
	var inst := card_ui.card_instance
	if inst.is_spell:
		return false
	if is_hand_card.call(card_ui):
		return inst.get_attribute("cost") <= get_mana.call()
	# Board-to-board MOVE legality (the accept-side twin of CardUI._get_drag_data's gates):
	# only the player's own fielded, non-building units relocate — a fielded building's drag
	# exists solely to cast its armed ability, and no move spot ever accepts it.
	if inst.owner != 0:
		return false
	if inst.row >= 0 and inst.data.is_building():
		return false
	return true


# The occupied-slot gate consulted by SlotUI._can_drop_data — occupied slots reject unit
# drops except the autocast gesture (see `can_autocast`).
func _can_autocast_on_slot(card_ui: CardUI, slot: SlotUI) -> bool:
	return placement_enabled and can_autocast.is_valid() \
			and bool(can_autocast.call(card_ui.card_instance, slot))


func _on_player_slot_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if card_ui.card_instance.is_spell:
		spell_dropped.emit(slot, card_ui)
		return
	if not placement_enabled:
		return
	if slot.get_card() != null:
		# A drop onto an occupied slot only got here through the autocast gate
		# (SlotUI._can_drop_data → _can_autocast_on_slot): fire the ability, don't place.
		autocast_dropped.emit(slot, card_ui)
		return
	do_place_unit(slot, card_ui)


func _on_enemy_slot_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if card_ui.card_instance.is_spell:
		spell_dropped.emit(slot, card_ui)


# Every PLAYER board unit joins the autocast drag affordance, whatever path fielded it (hand
# placement, move, material spawn, the king). Re-entry (a relocating unit) is guarded.
func _wire_unit_drag(card_ui: CardUI) -> void:
	if not card_ui.unit_drag_started.is_connected(_on_unit_drag_started):
		card_ui.unit_drag_started.connect(_on_unit_drag_started)
		card_ui.unit_drag_ended.connect(_on_unit_drag_ended)


# A fielded unit's drag doubles as the autocast gesture. Card mouse filters must drop for the
# drag's duration regardless of armed state (an occupied slot's occupant CardUI would swallow
# the drop otherwise — same reason SpellCaster does this for spell drags); the target
# highlight only lights when something is actually armed.
func _on_unit_drag_started(card_ui: CardUI) -> void:
	set_board_card_filters(false)
	if card_ui.card_instance.armed_autocast() == null:
		return
	set_slots_targetable_by_slot(true, func(slot: SlotUI) -> bool:
		return slot.get_card() != null and _can_autocast_on_slot(card_ui, slot))


func _on_unit_drag_ended(_card_ui: CardUI) -> void:
	set_board_card_filters(true)
	set_slots_targetable(false)


func do_place_unit(slot: SlotUI, card_ui: CardUI) -> void:
	var inst      := card_ui.card_instance
	var from_hand: bool = is_hand_card.call(card_ui)
	var cost      := inst.get_attribute("cost")

	if from_hand and cost > get_mana.call():
		return

	# Buildings are rooted once placed — never relocate an already-placed one.
	# (CardUI._get_drag_data normally prevents the drag from even starting.)
	if not from_hand and inst.data.is_building():
		return

	if not from_hand and inst.row >= 0 and inst.col >= 0:
		player_grid[inst.row][inst.col] = null

	inst.row = slot.row; inst.col = slot.col; inst.owner = 0
	player_grid[slot.row][slot.col] = inst
	slot.set_card(card_ui)
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach

	_wire_unit_drag(card_ui)

	var results: Array = []
	if from_hand:
		card_ui._show_cost = false
		results = EffectSystem.trigger(
			GameEvent.make(&"play", inst), inst, make_context(inst))
		cleanup_effect_deaths()

	refresh()
	unit_placed.emit(inst, card_ui, from_hand, cost if from_hand else 0, results)
