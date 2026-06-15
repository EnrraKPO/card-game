extends Control

const HUD_HEIGHT := 72.0

enum Phase { CPU_PLACE, PLAYER_PLACE, COMBAT }

var _player_grid: Array = []     # [row][col] -> CardInstance or null
var _enemy_grid: Array = []      # [row][col] -> CardInstance or null
var _draw_pile: Array = []       # Array[CardInstance]
var _hand_cards: Array = []      # Array[CardUI]
var _enemy_hand: Array = []      # Array[CardInstance]
var _mana: int = 0
var _max_mana: int = 0
var _enemy_mana: int = 0
var _turn: int = 0
var _phase: Phase = Phase.CPU_PLACE

var _turn_label: Label
var _mana_label: Label
var _done_btn: Button
var _player_slots: Array = []    # [row][col] -> SlotUI
var _enemy_slots: Array = []     # [row][col] -> SlotUI
var _hand_box: BoxContainer
var _selected_hand_card: CardUI = null


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_init_grids()
	_init_player_hand()
	_init_enemy_hand()
	_build_ui()
	_place_kings()
	_create_hand_cards()
	_refresh()
	_begin_round()


# ── Initialisation ─────────────────────────────────────────────────────────────

func _init_grids() -> void:
	for r in BoardData.ROWS:
		_player_grid.append([])
		_enemy_grid.append([])
		_player_slots.append([])
		_enemy_slots.append([])
		for c in BoardData.COLS:
			_player_grid[r].append(null)
			_enemy_grid[r].append(null)
			_player_slots[r].append(null)
			_enemy_slots[r].append(null)


func _init_player_hand() -> void:
	var deck_ids: Array = GameData.current_run.deck.duplicate()
	deck_ids.shuffle()
	for id in deck_ids:
		var data := CardData.get_card(id)
		if data and not data.is_king:
			_draw_pile.append(CardInstance.from_data(data))
	var to_draw := mini(4, _draw_pile.size())
	for i in to_draw:
		_draw_pile[i].row = -1
		_draw_pile[i].col = -1
	_draw_pile = _draw_pile  # keep full pile; hand is populated in _create_hand_cards


func _init_enemy_hand() -> void:
	var ids := ["strike", "strike", "strike", "defender", "defender", "swift", "warrior", "archer"]
	ids.shuffle()
	for id in ids:
		var data := CardData.get_card(id)
		if data:
			_enemy_hand.append(CardInstance.from_data(data))


func _place_kings() -> void:
	var back_row := BoardData.ROWS - 1

	var pk := CardInstance.from_data(CardData.get_card("king"))
	pk.row = back_row
	pk.col = 0
	pk.owner = 0
	_player_grid[back_row][0] = pk
	_player_slots[back_row][0].set_card(CardUI.create(pk))

	var ek := CardInstance.from_data(CardData.get_card("king"))
	ek.row = back_row
	ek.col = BoardData.COLS - 1
	ek.owner = 1
	_enemy_grid[back_row][BoardData.COLS - 1] = ek
	_enemy_slots[back_row][BoardData.COLS - 1].set_card(CardUI.create(ek))


func _create_hand_cards() -> void:
	var to_draw := mini(4, _draw_pile.size())
	for i in to_draw:
		var inst: CardInstance = _draw_pile[i]
		inst.row = -1
		inst.col = -1
		var ui := CardUI.create(inst, true)
		_hand_cards.append(ui)
		_hand_box.add_child(ui)
		var captured := ui
		captured.pressed.connect(func(): _on_hand_card_pressed(captured))
	_draw_pile = _draw_pile.slice(to_draw)


# ── Round flow ─────────────────────────────────────────────────────────────────

func _begin_round() -> void:
	_turn += 1
	_max_mana = mini(_turn, 10)
	_mana = _max_mana
	_enemy_mana = _max_mana
	_draw_card()
	await _do_cpu_placement()
	_phase = Phase.PLAYER_PLACE
	_set_placement_input(true)
	_refresh()


func _draw_card() -> void:
	if _draw_pile.is_empty():
		return
	var inst: CardInstance = _draw_pile[0]
	inst.row = -1
	inst.col = -1
	_draw_pile = _draw_pile.slice(1)
	var ui := CardUI.create(inst, true)
	_hand_cards.append(ui)
	_hand_box.add_child(ui)
	ui.pressed.connect(func(): _on_hand_card_pressed(ui))


func _do_cpu_placement() -> void:
	_phase = Phase.CPU_PLACE
	_set_placement_input(false)
	_refresh_done_btn()

	var empty_slots: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if _enemy_grid[r][c] == null:
				empty_slots.append([r, c])
	empty_slots.shuffle()

	var shuffled_hand := _enemy_hand.duplicate()
	shuffled_hand.shuffle()

	for inst: CardInstance in shuffled_hand:
		if empty_slots.is_empty():
			break
		if inst.data.cost <= _enemy_mana:
			var pos: Array = empty_slots.pop_front()
			var r: int = pos[0]
			var c: int = pos[1]
			inst.row = r
			inst.col = c
			inst.owner = 1
			_enemy_grid[r][c] = inst
			_enemy_mana -= inst.data.cost
			_enemy_hand.erase(inst)
			var ui := CardUI.create(inst)
			_enemy_slots[r][c].set_card(ui)
			var cpu_results := EffectSystem.trigger(Effect.Trigger.ON_PLAY, inst, EffectContext.make(inst, _player_grid, _enemy_grid))
			_show_effect_results(cpu_results)
			_cleanup_effect_deaths()
			_refresh_boards()
			_animate_card_placed(ui)
			await get_tree().create_timer(0.35).timeout


func _on_done_pressed() -> void:
	_deselect_hand_card()
	_phase = Phase.COMBAT
	_set_placement_input(false)
	_refresh()
	await _run_combat()
	if _any_king_dead():
		_handle_combat_end()
		return
	await get_tree().create_timer(0.8).timeout
	await _begin_round()


# ── Combat resolution ──────────────────────────────────────────────────────────

func _run_combat() -> void:
	var all_cards: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if _player_grid[r][c] != null:
				all_cards.append(_player_grid[r][c])
			if _enemy_grid[r][c] != null:
				all_cards.append(_enemy_grid[r][c])

	all_cards.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var spd_a := a.get_attribute("speed")
		var spd_b := b.get_attribute("speed")
		if spd_a != spd_b:
			return spd_a > spd_b
		if a.owner != b.owner:
			return a.owner < b.owner
		var prox_a := a.col if a.owner == 0 else BoardData.COLS - 1 - a.col
		var prox_b := b.col if b.owner == 0 else BoardData.COLS - 1 - b.col
		if prox_a != prox_b:
			return prox_a > prox_b
		return a.row > b.row
	)

	for attacker: CardInstance in all_cards:
		if not attacker.is_alive():
			continue
		var target_board := _enemy_grid if attacker.owner == 0 else _player_grid
		var target := _find_target(attacker, target_board)
		if target == null:
			continue

		var a_card: CardUI = _get_card_ui(attacker)
		var t_card: CardUI = _get_card_ui(target)

		var a_home := a_card.global_position
		var ghost := _spawn_ghost(a_card)
		a_card.modulate.a = 0.0

		var lunge := create_tween()
		lunge.set_ease(Tween.EASE_IN)
		lunge.set_trans(Tween.TRANS_QUAD)
		lunge.tween_property(ghost, "global_position", t_card.global_position, 0.3)
		await lunge.finished

		await _shake_card(t_card)
		var dmg := attacker.get_attribute("attack")
		var atk_results := EffectSystem.trigger(Effect.Trigger.ON_ATTACK, attacker, EffectContext.make(attacker, _player_grid, _enemy_grid))
		_show_effect_results(atk_results)
		target.take_damage(dmg)
		var dtk_results := EffectSystem.trigger(Effect.Trigger.ON_DAMAGE_TAKEN, target, EffectContext.make(target, _player_grid, _enemy_grid))
		_show_effect_results(dtk_results)
		_spawn_damage_label(t_card, dmg)
		_tween_flash(t_card, Color(2.0, 0.3, 0.3), Color.WHITE, 0.35)

		var retreat := create_tween()
		retreat.set_ease(Tween.EASE_OUT)
		retreat.set_trans(Tween.TRANS_QUAD)
		retreat.tween_property(ghost, "global_position", a_home, 0.2)
		await retreat.finished
		ghost.queue_free()
		a_card.modulate.a = 1.0

		if not target.is_alive():
			var death_results := EffectSystem.trigger(Effect.Trigger.ON_DEATH, target, EffectContext.make(target, _player_grid, _enemy_grid))
			_show_effect_results(death_results)
			await _animate_death(t_card)
			_remove_card_from_grid(target)
		else:
			t_card.refresh()
			await get_tree().create_timer(0.2).timeout


func _find_target(attacker: CardInstance, target_board: Array) -> CardInstance:
	var best: CardInstance = null
	var best_dist := 999
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var candidate: CardInstance = target_board[r][c]
			if candidate == null:
				continue
			var dist: int = abs(attacker.row + r - (BoardData.ROWS - 1))
			if attacker.owner == 0:
				dist += BoardData.COLS + c - attacker.col
			else:
				dist += BoardData.COLS + attacker.col - c
			if dist < best_dist:
				best_dist = dist
				best = candidate
	return best


func _get_card_ui(inst: CardInstance) -> CardUI:
	if inst.owner == 0:
		return _player_slots[inst.row][inst.col].get_card()
	return _enemy_slots[inst.row][inst.col].get_card()


func _remove_card_from_grid(inst: CardInstance) -> void:
	var slots := _player_slots if inst.owner == 0 else _enemy_slots
	var board := _player_grid if inst.owner == 0 else _enemy_grid
	var card_ui: CardUI = (slots[inst.row][inst.col] as SlotUI).clear_card()
	board[inst.row][inst.col] = null
	if card_ui:
		card_ui.queue_free()


func _any_king_dead() -> bool:
	var player_king := false
	var enemy_king := false
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if _player_grid[r][c] != null and _player_grid[r][c].data.is_king:
				player_king = true
			if _enemy_grid[r][c] != null and _enemy_grid[r][c].data.is_king:
				enemy_king = true
	return not player_king or not enemy_king


func _handle_combat_end() -> void:
	# TODO: show win/lose screen before returning to map
	GameData.save_run()
	get_tree().change_scene_to_file("res://scenes/map.tscn")


# ── UI building ────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(root)

	_build_hud(root)

	var boards := HBoxContainer.new()
	boards.size_flags_vertical = SIZE_EXPAND_FILL
	boards.add_theme_constant_override("separation", 0)
	root.add_child(boards)

	_build_board_section(boards, true)
	boards.add_child(VSeparator.new())
	_build_board_section(boards, false)

	_build_hand_area(root)


func _build_hud(parent: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = HUD_HEIGHT
	parent.add_child(panel)

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)

	var run: RunData = GameData.current_run

	var hp := Label.new()
	hp.text = "  HP  %d / %d" % [run.health, run.max_health]
	hp.add_theme_font_size_override("font_size", 22)
	hp.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(hp)

	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 22)
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_label.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(_turn_label)

	_mana_label = Label.new()
	_mana_label.add_theme_font_size_override("font_size", 22)
	_mana_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mana_label.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(_mana_label)

	_done_btn = Button.new()
	_done_btn.custom_minimum_size = Vector2(200, 0)
	_done_btn.add_theme_font_size_override("font_size", 18)
	_done_btn.pressed.connect(_on_done_pressed)
	hbox.add_child(_done_btn)


func _build_board_section(parent: BoxContainer, is_player: bool) -> void:
	var section := VBoxContainer.new()
	section.size_flags_horizontal = SIZE_EXPAND_FILL
	section.size_flags_vertical = SIZE_EXPAND_FILL
	parent.add_child(section)

	var label := Label.new()
	label.text = "Player" if is_player else "Enemy"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	section.add_child(label)

	var center := CenterContainer.new()
	center.size_flags_vertical = SIZE_EXPAND_FILL
	section.add_child(center)

	var grid := GridContainer.new()
	grid.columns = BoardData.COLS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	center.add_child(grid)

	var row_order := range(BoardData.ROWS) if is_player \
		else range(BoardData.ROWS - 1, -1, -1)

	for r in row_order:
		for c in BoardData.COLS:
			var slot := SlotUI.new()
			slot.row = r
			slot.col = c
			slot.owner_id = 0 if is_player else 1

			if is_player:
				_player_slots[r][c] = slot
				slot.accept_check = _can_drop_on_player_slot
				var s := slot
				s.card_dropped.connect(func(cu: CardUI): _on_player_slot_card_dropped(s, cu))
				s.pressed.connect(func(): _on_slot_pressed(s))
			else:
				_enemy_slots[r][c] = slot

			grid.add_child(slot)


func _build_hand_area(parent: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 210.0
	parent.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 12)
	scroll.add_child(_hand_box)


# ── Display refresh ────────────────────────────────────────────────────────────

func _refresh() -> void:
	if _turn_label:
		_turn_label.text = "Turn %d" % _turn
	_refresh_mana()
	_refresh_boards()
	_refresh_hand()
	_refresh_done_btn()


func _refresh_mana() -> void:
	if _mana_label:
		_mana_label.text = "Mana  %d / %d  " % [_mana, _max_mana]


func _refresh_boards() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (_player_slots[r][c] as SlotUI).get_card()
			if p:
				p.refresh()
			var e: CardUI = (_enemy_slots[r][c] as SlotUI).get_card()
			if e:
				e.refresh()


func _refresh_hand() -> void:
	for ui in _hand_cards:
		ui.refresh()


func _refresh_done_btn() -> void:
	if _done_btn == null:
		return
	match _phase:
		Phase.PLAYER_PLACE:
			_done_btn.text = "Done Placing"
			_done_btn.disabled = false
		Phase.CPU_PLACE:
			_done_btn.text = "CPU is placing..."
			_done_btn.disabled = true
		Phase.COMBAT:
			_done_btn.text = "Combat..."
			_done_btn.disabled = true


func _set_placement_input(enabled: bool) -> void:
	var filter := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for ui: CardUI in _hand_cards:
		ui.mouse_filter = filter
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (_player_slots[r][c] as SlotUI).get_card()
			if p:
				p.mouse_filter = filter


# ── Drop handlers ──────────────────────────────────────────────────────────────

func _can_drop_on_player_slot(card_ui: CardUI, slot: SlotUI) -> bool:
	var inst := card_ui.card_instance
	if _hand_cards.has(card_ui):
		return inst.data.cost <= _mana
	return true


func _on_player_slot_card_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if _phase != Phase.PLAYER_PLACE:
		return

	var inst := card_ui.card_instance
	var from_hand := _hand_cards.has(card_ui)

	if from_hand:
		if inst.data.cost > _mana:
			return
		if _selected_hand_card == card_ui:
			_deselect_hand_card()
		_mana -= inst.data.cost
		_hand_cards.erase(card_ui)
		card_ui._show_cost = false
		_refresh_mana()
	else:
		# Moving between player slots — clear old grid cell
		if inst.row >= 0 and inst.col >= 0:
			_player_grid[inst.row][inst.col] = null

	inst.row = slot.row
	inst.col = slot.col
	inst.owner = 0
	_player_grid[slot.row][slot.col] = inst
	slot.set_card(card_ui)
	if from_hand:
		var play_results := EffectSystem.trigger(Effect.Trigger.ON_PLAY, inst, EffectContext.make(inst, _player_grid, _enemy_grid))
		_show_effect_results(play_results)
		_cleanup_effect_deaths()
	_refresh_boards()
	_animate_card_placed(card_ui)



# ── Selection (click-to-place) ─────────────────────────────────────────────────

func _on_hand_card_pressed(card_ui: CardUI) -> void:
	if _phase != Phase.PLAYER_PLACE:
		return
	if _selected_hand_card == card_ui:
		_deselect_hand_card()
	else:
		if _selected_hand_card != null:
			_deselect_hand_card()
		_selected_hand_card = card_ui
		card_ui.set_selected(true)


func _deselect_hand_card() -> void:
	if _selected_hand_card != null:
		_selected_hand_card.set_selected(false)
		_selected_hand_card = null


func _on_slot_pressed(slot: SlotUI) -> void:
	if _phase != Phase.PLAYER_PLACE or _selected_hand_card == null:
		return
	if slot.get_card() != null:
		return
	if not _can_drop_on_player_slot(_selected_hand_card, slot):
		return
	var card := _selected_hand_card
	_deselect_hand_card()
	_on_player_slot_card_dropped(slot, card)


# ── Animation helpers ──────────────────────────────────────────────────────────

func _spawn_ghost(source: CardUI) -> CardUI:
	var ghost := CardUI.create(source.card_instance)
	ghost.z_index = 20
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.custom_minimum_size = source.size
	add_child(ghost)
	ghost.global_position = source.global_position
	return ghost


func _animate_card_placed(card: CardUI) -> void:
	if card == null:
		return
	card.modulate = Color(1.6, 1.6, 0.5)
	var tween := create_tween()
	tween.tween_property(card, "modulate", Color.WHITE, 0.3)


func _tween_flash(card: CardUI, flash_color: Color, return_color: Color, duration: float) -> void:
	if card == null:
		return
	var tween := create_tween()
	tween.tween_property(card, "modulate", flash_color, duration * 0.3)
	tween.tween_property(card, "modulate", return_color, duration * 0.7)


func _animate_death(card: CardUI) -> void:
	if card == null:
		return
	var tween := create_tween()
	tween.tween_property(card, "modulate", Color(0.6, 0.1, 0.1, 0.0), 0.4)
	await tween.finished


func _shake_card(card: CardUI) -> void:
	if card == null:
		return
	var origin := card.position
	var d := 6.0
	var t := 0.04
	var tw := create_tween()
	tw.tween_property(card, "position", origin + Vector2(d, 0), t)
	tw.tween_property(card, "position", origin + Vector2(-d, 0), t)
	tw.tween_property(card, "position", origin + Vector2(d * 0.5, 0), t)
	tw.tween_property(card, "position", origin + Vector2(-d * 0.5, 0), t)
	tw.tween_property(card, "position", origin, t)
	await tw.finished


func _show_effect_results(results: Array) -> void:
	for r: Dictionary in results:
		if r.is_empty():
			continue
		var target: CardInstance = r.get("target")
		if target == null or target.row < 0 or target.col < 0:
			continue
		var card_ui := _get_card_ui(target)
		if card_ui == null:
			continue
		_spawn_effect_label(card_ui, r.get("attribute", ""), r.get("delta", 0))


func _spawn_effect_label(card_ui: CardUI, attribute: String, delta: int) -> void:
	if delta == 0:
		return
	var lbl := Label.new()
	var sign := "+" if delta > 0 else ""
	match attribute:
		"health":
			lbl.text = "%s%d HP" % [sign, delta]
			lbl.modulate = Color(0.3, 1.0, 0.3) if delta > 0 else Color(1.0, 0.4, 0.4)
		"attack":
			lbl.text = "%s%d ATK" % [sign, delta]
			lbl.modulate = Color(1.0, 0.85, 0.1)
		"speed":
			lbl.text = "%s%d SPD" % [sign, delta]
			lbl.modulate = Color(0.3, 0.8, 1.0)
		_:
			lbl.text = "%s%d %s" % [sign, delta, attribute.to_upper()]
			lbl.modulate = Color(1.0, 1.0, 1.0)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.z_index = 15
	lbl.position = card_ui.global_position + Vector2(card_ui.size.x * 0.5 - 20.0, 0.0)
	add_child(lbl)
	var tween := create_tween()
	tween.tween_property(lbl, "position:y", lbl.position.y - 60.0, 0.7)
	tween.parallel().tween_property(lbl, "modulate:a", 0.0, 0.7)
	tween.tween_callback(lbl.queue_free)


func _cleanup_effect_deaths() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardInstance = _player_grid[r][c]
			if p != null and not p.is_alive():
				_remove_card_from_grid(p)
			var e: CardInstance = _enemy_grid[r][c]
			if e != null and not e.is_alive():
				_remove_card_from_grid(e)


func _spawn_damage_label(card: CardUI, amount: int) -> void:
	if card == null:
		return
	var lbl := Label.new()
	lbl.text = "-%d" % amount
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.modulate = Color(1.0, 0.25, 0.25)
	lbl.z_index = 10
	lbl.position = card.global_position + card.size * 0.5 - Vector2(20, 20)
	add_child(lbl)
	var tween := create_tween()
	tween.tween_property(lbl, "position:y", lbl.position.y - 64.0, 0.6)
	tween.parallel().tween_property(lbl, "modulate:a", 0.0, 0.6)
	tween.tween_callback(lbl.queue_free)
