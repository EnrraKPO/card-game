extends Control

const HUD_HEIGHT := 72.0

enum Phase { CPU_PLACE, PLAYER_PLACE, COMBAT, TARGETING }

var _phase: Phase = Phase.CPU_PLACE
var _mana: int    = 0
var _max_mana: int = 0
var _enemy_mana: int = 0
var _turn: int    = 0

var _draw_pile: Array  = []  # Array[CardInstance]
var _hand_cards: Array = []  # Array[CardUI]
var _enemy_hand: Array = []  # Array[CardInstance]
var _selected_hand_card: CardUI = null

var _turn_label: Label
var _mana_label: Label
var _done_btn: Button
var _hand_box: BoxContainer

var _board: CombatBoard
var _animator: CombatAnimator
var _spell_caster: SpellCaster


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	_board        = CombatBoard.new()
	_animator     = CombatAnimator.new()
	_spell_caster = SpellCaster.new()
	add_child(_board)
	add_child(_animator)
	add_child(_spell_caster)

	_board.setup_grids()
	_board.is_hand_card = func(cu: CardUI) -> bool: return _hand_cards.has(cu)
	_board.get_mana     = func() -> int:            return _mana

	_animator.setup(self, func(inst: CardInstance) -> CardUI: return _board.get_card_ui(inst))

	_spell_caster.setup(_board, _animator, func() -> int: return _mana)

	_board.unit_placed.connect(_on_board_unit_placed)
	_board.slot_pressed.connect(_on_board_slot_pressed)
	_spell_caster.targeting_started.connect(_on_targeting_started)
	_spell_caster.targeting_ended.connect(_on_targeting_ended)
	_spell_caster.spell_consumed.connect(_on_spell_consumed)

	_init_player_hand()
	_init_enemy_hand()
	_build_ui()
	_board.place_kings()
	_create_hand_cards()
	_refresh()
	_begin_round()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed \
				and _spell_caster.is_targeting():
			_spell_caster.cancel_targeting()
			get_viewport().set_input_as_handled()


# ── Hand initialisation ────────────────────────────────────────────────────────

func _init_player_hand() -> void:
	var ids: Array = GameData.current_run.deck.duplicate()
	ids.shuffle()
	for id in ids:
		var data := CardData.get_card(id)
		if data and not data.is_king:
			_draw_pile.append(CardInstance.from_data(data))


func _init_enemy_hand() -> void:
	var ids: Array = []
	if GameData.current_encounter != null:
		ids = GameData.current_encounter.enemy_deck.duplicate()
	else:
		ids = ["strike", "strike", "strike", "defender", "defender", "swift", "warrior", "archer"]
	ids.shuffle()
	for id in ids:
		var data := CardData.get_card(id)
		if data and not data.is_king and data.card_type == CardData.CardType.UNIT:
			_enemy_hand.append(CardInstance.from_data(data))


func _create_hand_cards() -> void:
	var to_draw := mini(4, _draw_pile.size())
	for i in to_draw:
		var inst: CardInstance = _draw_pile[i]
		inst.row = -1
		inst.col = -1
		var ui := CardUI.create(inst, true)
		_hand_cards.append(ui)
		_hand_box.add_child(ui)
		_wire_hand_card(ui)
	_draw_pile = _draw_pile.slice(to_draw)


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
	_wire_hand_card(ui)


func _wire_hand_card(ui: CardUI) -> void:
	if ui.card_instance.is_spell:
		_spell_caster.wire_spell_card(ui)
	else:
		ui.pressed.connect(func(): _on_hand_card_pressed(ui))


# ── Round flow ─────────────────────────────────────────────────────────────────

func _begin_round() -> void:
	_turn      += 1
	_max_mana   = mini(_turn, 10)
	_mana       = _max_mana
	_enemy_mana = _max_mana
	_draw_card()
	await _do_cpu_placement()
	_phase = Phase.PLAYER_PLACE
	_board.placement_enabled = true
	_set_placement_input(true)
	_refresh()


func _do_cpu_placement() -> void:
	_phase = Phase.CPU_PLACE
	_board.placement_enabled = false
	_set_placement_input(false)
	_refresh_done_btn()

	var ai: EnemyAI = EnemyAI.new()
	if GameData.current_encounter != null and GameData.current_encounter.ai != null:
		ai = GameData.current_encounter.ai

	var placements := ai.decide_placements(_enemy_hand, _board.enemy_grid, _enemy_mana)

	for placement: Dictionary in placements:
		var inst: CardInstance = placement["inst"]
		var r: int             = placement["row"]
		var c: int             = placement["col"]
		_enemy_mana -= inst.data.cost
		_enemy_hand.erase(inst)
		var results := _board.place_enemy_card(inst, r, c)
		_animator.show_effect_results(results)
		_animator.animate_card_placed(_board.get_card_ui(inst))
		await get_tree().create_timer(0.35).timeout


func _on_done_pressed() -> void:
	_deselect_hand_card()
	_phase = Phase.COMBAT
	_board.placement_enabled = false
	_set_placement_input(false)
	_refresh()
	await _run_combat()
	if _board.any_king_dead():
		_handle_combat_end()
		return
	await get_tree().create_timer(0.8).timeout
	await _begin_round()


# ── Combat resolution ──────────────────────────────────────────────────────────

func _run_combat() -> void:
	var all_cards := _board.get_all_units()
	all_cards.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var sa := a.get_attribute("speed")
		var sb := b.get_attribute("speed")
		if sa != sb:
			return sa > sb
		if a.owner != b.owner:
			return a.owner < b.owner
		var pa := a.col if a.owner == 0 else BoardData.COLS - 1 - a.col
		var pb := b.col if b.owner == 0 else BoardData.COLS - 1 - b.col
		if pa != pb:
			return pa > pb
		return a.row > b.row
	)

	for attacker: CardInstance in all_cards:
		if not attacker.is_alive():
			continue
		var target := _board.find_target(attacker)
		if target == null:
			continue

		var a_card := _board.get_card_ui(attacker)
		var t_card := _board.get_card_ui(target)
		var a_home := a_card.global_position

		var ghost := _animator.spawn_ghost(a_card)
		a_card.modulate.a = 0.0
		await _animator.play_lunge(ghost, t_card.global_position)

		await _animator.shake_card(t_card)
		var dmg := attacker.get_attribute("attack")
		var atk_results := EffectSystem.trigger(Effect.Trigger.ON_ATTACK, attacker,
			EffectContext.make(attacker, _board.player_grid, _board.enemy_grid))
		_animator.show_effect_results(atk_results)
		target.take_damage(dmg)
		var dtk_results := EffectSystem.trigger(Effect.Trigger.ON_DAMAGE_TAKEN, target,
			EffectContext.make(target, _board.player_grid, _board.enemy_grid))
		_animator.show_effect_results(dtk_results)
		_animator.spawn_damage_label(t_card, dmg)
		_animator.tween_flash(t_card, Color(2.0, 0.3, 0.3), Color.WHITE, 0.35)

		await _animator.play_retreat(ghost, a_home)
		ghost.queue_free()
		a_card.modulate.a = 1.0

		if not target.is_alive():
			var death_results := EffectSystem.trigger(Effect.Trigger.ON_DEATH, target,
				EffectContext.make(target, _board.player_grid, _board.enemy_grid))
			_animator.show_effect_results(death_results)
			await _animator.animate_death(t_card)
			_board.remove_card(target)
		else:
			t_card.refresh()
			await get_tree().create_timer(0.2).timeout


func _handle_combat_end() -> void:
	var player_won := _board.player_king_alive()
	var enc        := GameData.current_encounter
	if enc != null:
		enc.outcome = EncounterData.Outcome.WIN if player_won else EncounterData.Outcome.LOSE
	if player_won:
		GameData.save_run()
		get_tree().change_scene_to_file("res://scenes/reward_screen.tscn")
	else:
		var penalty := 15
		if enc != null:
			match enc.type:
				EncounterData.Type.ELITE: penalty = 25
				EncounterData.Type.BOSS:  penalty = GameData.current_run.health
		GameData.current_run.health = max(0, GameData.current_run.health - penalty)
		GameData.save_run()
		get_tree().change_scene_to_file("res://scenes/map.tscn")


# ── Board event handlers ───────────────────────────────────────────────────────

func _on_board_unit_placed(_inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, results: Array) -> void:
	if from_hand:
		_mana -= cost
		if _selected_hand_card == card_ui:
			_deselect_hand_card()
		_hand_cards.erase(card_ui)
		_refresh_mana()
	_animator.show_effect_results(results)
	_animator.animate_card_placed(card_ui)


func _on_board_slot_pressed(slot: SlotUI) -> void:
	if _spell_caster.is_targeting():
		return  # spell_caster handles via its own slot_pressed connection
	if _phase != Phase.PLAYER_PLACE or _selected_hand_card == null:
		return
	if slot.get_card() != null:
		return
	if not _board.can_place_from_hand(_selected_hand_card):
		return
	var card := _selected_hand_card
	_deselect_hand_card()
	_board.do_place_unit(slot, card)


# ── Spell phase bridging ───────────────────────────────────────────────────────

func _on_targeting_started() -> void:
	_phase = Phase.TARGETING
	_set_placement_input(false)
	_refresh_done_btn()


func _on_targeting_ended() -> void:
	_phase = Phase.PLAYER_PLACE
	_set_placement_input(true)
	_refresh_done_btn()


func _on_spell_consumed(card_ui: CardUI, cost: int) -> void:
	_mana -= cost
	_hand_cards.erase(card_ui)
	_refresh_mana()


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

	_board.build_section(boards, true)
	boards.add_child(VSeparator.new())
	_board.build_section(boards, false)

	_build_hand_area(root)


func _build_hud(parent: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = HUD_HEIGHT
	parent.add_child(panel)

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)
	hbox.add_child(RunHUD.new())

	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 17)
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_label.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(_turn_label)

	_mana_label = Label.new()
	_mana_label.add_theme_font_size_override("font_size", 17)
	_mana_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mana_label.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(_mana_label)

	_done_btn = Button.new()
	_done_btn.custom_minimum_size = Vector2(200, 0)
	_done_btn.add_theme_font_size_override("font_size", 18)
	_done_btn.pressed.connect(_on_done_pressed)
	hbox.add_child(_done_btn)

	var dbg_win := Button.new()
	dbg_win.text = "[debug] win"
	dbg_win.add_theme_font_size_override("font_size", 13)
	dbg_win.modulate = Color(1.0, 0.65, 0.1)
	dbg_win.pressed.connect(_handle_combat_end)
	hbox.add_child(dbg_win)


func _build_hand_area(parent: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 210.0
	parent.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 12)
	scroll.add_child(_hand_box)


# ── Display refresh ────────────────────────────────────────────────────────────

func _refresh() -> void:
	if _turn_label:
		_turn_label.text = "Turn %d" % _turn
	_refresh_mana()
	_board.refresh()
	_refresh_hand()
	_refresh_done_btn()


func _refresh_mana() -> void:
	if _mana_label:
		_mana_label.text = "Mana  %d / %d  " % [_mana, _max_mana]


func _refresh_hand() -> void:
	for ui in _hand_cards:
		ui.refresh()


func _refresh_done_btn() -> void:
	if _done_btn == null:
		return
	match _phase:
		Phase.PLAYER_PLACE:
			_done_btn.text     = "Done Placing"
			_done_btn.disabled = false
		Phase.CPU_PLACE:
			_done_btn.text     = "CPU is placing..."
			_done_btn.disabled = true
		Phase.COMBAT:
			_done_btn.text     = "Combat..."
			_done_btn.disabled = true
		Phase.TARGETING:
			_done_btn.text     = "Select a target..."
			_done_btn.disabled = true


# ── Hand input ─────────────────────────────────────────────────────────────────

func _set_placement_input(enabled: bool) -> void:
	var filter := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for ui: CardUI in _hand_cards:
		ui.mouse_filter = filter
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (_board.player_slots[r][c] as SlotUI).get_card()
			if p:
				p.mouse_filter = filter


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
