class_name SpellCaster
extends Node

signal targeting_started
signal targeting_ended
signal spell_consumed(card_ui: CardUI, mana_cost: int)

var board: CombatBoard
var animator: CombatAnimator
var get_mana: Callable  # func() -> int

var _is_targeting: bool  = false
var _pending_spell: CardUI = null
var _pending_allow_royalty: bool = true   # whether the in-flight spell may target royalty

signal _target_chosen(target: CardInstance)


func setup(p_board: CombatBoard, p_animator: CombatAnimator, p_get_mana: Callable) -> void:
	board    = p_board
	animator = p_animator
	get_mana = p_get_mana
	board.slot_pressed.connect(_on_slot_pressed)
	board.spell_dropped.connect(_on_spell_dropped)


# ── Public API ─────────────────────────────────────────────────────────────────

func wire_spell_card(ui: CardUI) -> void:
	ui.pressed.connect(func(): _on_spell_card_pressed(ui))
	ui.spell_drag_started.connect(_on_spell_drag_started)
	ui.spell_drag_ended.connect(_on_spell_drag_ended)


func is_targeting() -> bool:
	return _is_targeting


func cancel_targeting() -> void:
	if _is_targeting:
		_target_chosen.emit(null)


# ── Spell input handlers ───────────────────────────────────────────────────────

func _on_spell_card_pressed(card_ui: CardUI) -> void:
	if not _can_afford(card_ui):
		return
	var needs_target := card_ui.card_instance.data.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY \
			and e.targeting_policy == Effect.TargetingPolicy.MANUAL)
	var manual_target: CardInstance = null
	if needs_target:
		card_ui.set_selected(true)
		manual_target = await _request_target(_spell_allows_royalty(card_ui))
		card_ui.set_selected(false)
		if manual_target == null:
			return
	_execute_spell(card_ui, manual_target)


func _on_spell_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if not card_ui.card_instance.is_spell:
		return
	var target_ui := slot.get_card()
	if target_ui == null:
		return
	# Royalty can only be hit if the spell opts in (lackeys-only by default).
	if target_ui.card_instance.data.is_royalty() and not _spell_allows_royalty(card_ui):
		return
	if not _can_afford(card_ui):
		return
	_execute_spell(card_ui, target_ui.card_instance)


func _on_spell_drag_started(card_ui: CardUI) -> void:
	if _is_targeting:
		return  # click-targeting session already active
	_pending_spell = card_ui
	_pending_allow_royalty = _spell_allows_royalty(card_ui)
	board.set_slots_targetable(true, _pending_allow_royalty)
	board.set_board_card_filters(false)


func _on_spell_drag_ended(card_ui: CardUI) -> void:
	board.set_slots_targetable(false)
	board.set_board_card_filters(true)
	if _pending_spell == card_ui:
		_pending_spell = null


func _on_slot_pressed(slot: SlotUI) -> void:
	if not _is_targeting:
		return
	var card := slot.get_card()
	if card == null:
		return
	# Ignore a royalty pick unless the in-flight spell opts in (the slot isn't highlighted either).
	if card.card_instance.data.is_royalty() and not _pending_allow_royalty:
		return
	_target_chosen.emit(card.card_instance)


# ── Core spell execution ───────────────────────────────────────────────────────

func _execute_spell(card_ui: CardUI, manual_target: CardInstance) -> void:
	var inst := card_ui.card_instance
	var cost := inst.get_attribute("cost")
	spell_consumed.emit(card_ui, cost)  # orchestrator deducts mana + removes from hand
	card_ui.queue_free()
	for effect: Effect in inst.data.effects:
		if effect.trigger != Effect.Trigger.ON_PLAY:
			continue
		var ctx := EffectContext.make(inst, board.player_grid, board.enemy_grid)
		ctx.manual_target = manual_target
		var results := EffectSystem.apply_single(effect, inst, ctx)
		animator.show_effect_results(results)
		board.cleanup_effect_deaths()
	board.refresh()


func _request_target(allow_royalty: bool = true) -> CardInstance:
	if board.get_all_units().is_empty():
		return null
	_is_targeting = true
	_pending_allow_royalty = allow_royalty
	board.set_slots_targetable(true, allow_royalty)
	targeting_started.emit()
	var target: CardInstance = await _target_chosen
	board.set_slots_targetable(false)
	_is_targeting = false
	targeting_ended.emit()
	return target


# Whether this spell's manual on-play effects opt into targeting royalty. If ANY manual effect
# allows it, the player may pick a King/Queen (the central filter still gates per-effect).
func _spell_allows_royalty(card_ui: CardUI) -> bool:
	return card_ui.card_instance.data.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY \
			and e.targeting_policy == Effect.TargetingPolicy.MANUAL \
			and e.targets_royalty)


func _can_afford(card_ui: CardUI) -> bool:
	return card_ui.card_instance.get_attribute("cost") <= get_mana.call()
