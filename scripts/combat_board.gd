class_name CombatBoard
extends Node

# Emitted when a player unit is placed; combat handles mana deduction + animation.
signal unit_placed(inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, on_play_results: Array)
# Emitted for any slot press; combat and spell_caster both listen.
signal slot_pressed(slot: SlotUI)
# Emitted when a spell is drag-dropped onto a slot; spell_caster handles.
signal spell_dropped(slot: SlotUI, card_ui: CardUI)

var player_grid: Array = []   # [row][col] -> CardInstance or null
var enemy_grid:  Array = []   # [row][col] -> CardInstance or null
var player_slots: Array = []  # [row][col] -> SlotUI
var enemy_slots:  Array = []  # [row][col] -> SlotUI

# Set by the orchestrator during setup.
var placement_enabled: bool  = false
var is_hand_card: Callable        # func(CardUI) -> bool
var get_mana: Callable            # func() -> int
var _default_strategy := TargetingNearest.new()


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
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	parent.add_child(section)

	var label := Label.new()
	label.text = "Player" if is_player else "Enemy"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	section.add_child(label)

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	section.add_child(center)

	var grid := GridContainer.new()
	grid.columns = BoardData.COLS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
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
				var s := slot
				s.card_dropped.connect(func(cu: CardUI): _on_player_slot_dropped(s, cu))
				s.pressed.connect(func(): slot_pressed.emit(s))
			else:
				enemy_slots[r][c] = slot
				var s := slot
				s.card_dropped.connect(func(cu: CardUI): _on_enemy_slot_dropped(s, cu))
				s.pressed.connect(func(): slot_pressed.emit(s))

			grid.add_child(slot)


func place_kings(player_king_id: String = "king") -> void:
	var back: int = BoardData.ROWS - 1

	var pk := CardInstance.from_data(CardData.get_card(player_king_id))
	pk.row = back; pk.col = 0; pk.owner = 0
	player_grid[back][0] = pk
	player_slots[back][0].set_card(CardUI.create(pk))

	var ek := CardInstance.from_data(CardData.get_card("king"))
	ek.row = back; ek.col = BoardData.COLS - 1; ek.owner = 1
	enemy_grid[back][BoardData.COLS - 1] = ek
	enemy_slots[back][BoardData.COLS - 1].set_card(CardUI.create(ek))


# ── Card operations ────────────────────────────────────────────────────────────

func can_place_from_hand(card_ui: CardUI) -> bool:
	if card_ui.card_instance.is_spell:
		return false
	return card_ui.card_instance.get_attribute("cost") <= get_mana.call()


func place_enemy_card(inst: CardInstance, r: int, c: int) -> Array:
	inst.row = r; inst.col = c; inst.owner = 1
	enemy_grid[r][c] = inst
	var ui := CardUI.create(inst)
	enemy_slots[r][c].set_card(ui)
	var results := EffectSystem.trigger(
		Effect.Trigger.ON_PLAY, inst,
		EffectContext.make(inst, player_grid, enemy_grid))
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
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardInstance = player_grid[r][c]
			if p != null and not p.is_alive():
				remove_card(p)
			var e: CardInstance = enemy_grid[r][c]
			if e != null and not e.is_alive():
				remove_card(e)


func refresh() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (player_slots[r][c] as SlotUI).get_card()
			if p:
				p.refresh()
			var e: CardUI = (enemy_slots[r][c] as SlotUI).get_card()
			if e:
				e.refresh()


func set_slots_targetable(enabled: bool) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			(player_slots[r][c] as SlotUI).set_targetable(enabled)
			(enemy_slots[r][c] as SlotUI).set_targetable(enabled)


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
	if card_ui.card_instance.is_spell:
		return false
	if is_hand_card.call(card_ui):
		return card_ui.card_instance.data.cost <= get_mana.call()
	return true


func _on_player_slot_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if card_ui.card_instance.is_spell:
		spell_dropped.emit(slot, card_ui)
		return
	if not placement_enabled:
		return
	do_place_unit(slot, card_ui)


func _on_enemy_slot_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if card_ui.card_instance.is_spell:
		spell_dropped.emit(slot, card_ui)


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

	var results: Array = []
	if from_hand:
		card_ui._show_cost = false
		results = EffectSystem.trigger(
			Effect.Trigger.ON_PLAY, inst,
			EffectContext.make(inst, player_grid, enemy_grid))
		cleanup_effect_deaths()

	refresh()
	unit_placed.emit(inst, card_ui, from_hand, cost if from_hand else 0, results)
