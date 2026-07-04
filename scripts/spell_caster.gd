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
var _targeting_spell: CardUI = null    # the spell whose click-targeting session is active
var _targeting_slot_mode: bool = false # true while the active session picks a SLOT (MANUAL_SLOT)

signal _target_chosen(target: CardInstance)
signal _slot_chosen(slot: SlotUI)


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
		if _targeting_slot_mode:
			_slot_chosen.emit(null)
		else:
			_target_chosen.emit(null)


# ── Spell input handlers ───────────────────────────────────────────────────────

func _on_spell_card_pressed(card_ui: CardUI) -> void:
	if not _can_afford(card_ui):
		return
	if _needs_slot(card_ui):
		# Slot-mode (MANUAL_SLOT, e.g. material delivery): the pick is a SLOT — occupied means
		# merge onto its unit, empty means the effect's spawn case.
		card_ui.set_selected(true)
		var slot := await _request_slot(card_ui)
		card_ui.set_selected(false)
		if slot == null:
			return
		var occupant := slot.get_card()
		await _execute_spell(card_ui,
				occupant.card_instance if occupant != null else null, slot)
		return
	var needs_target := card_ui.card_instance.data.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY \
			and e.targeting_policy == Effect.TargetingPolicy.MANUAL)
	var manual_target: CardInstance = null
	if needs_target:
		card_ui.set_selected(true)
		manual_target = await _request_target(card_ui)
		card_ui.set_selected(false)
		if manual_target == null:
			return
	await _execute_spell(card_ui, manual_target)


func _on_spell_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if not card_ui.card_instance.is_spell:
		return
	if not _can_afford(card_ui):
		return
	if _needs_slot(card_ui):
		# Slot-mode drop: an eligible EMPTY own slot is a valid pick (the spawn case).
		if not _slot_eligible(card_ui.card_instance, slot):
			return
		var occupant := slot.get_card()
		await _execute_spell(card_ui,
				occupant.card_instance if occupant != null else null, slot)
		return
	var target_ui := slot.get_card()
	if target_ui == null:
		return
	if not _eligible(card_ui.card_instance, target_ui.card_instance):
		return   # ineligible pick (e.g. Castling onto an already-Barriered unit) — spell kept
	await _execute_spell(card_ui, target_ui.card_instance)


func _on_spell_drag_started(card_ui: CardUI) -> void:
	if _is_targeting:
		return  # click-targeting session already active
	_pending_spell = card_ui
	if _needs_slot(card_ui):
		board.set_slots_targetable_by_slot(true, _slot_eligibility_of(card_ui))
	else:
		board.set_slots_targetable(true, _eligibility_of(card_ui))
	board.set_board_card_filters(false)


func _on_spell_drag_ended(card_ui: CardUI) -> void:
	board.set_slots_targetable(false)
	board.set_board_card_filters(true)
	if _pending_spell == card_ui:
		_pending_spell = null


func _on_slot_pressed(slot: SlotUI) -> void:
	if not _is_targeting:
		return
	if _targeting_slot_mode:
		if _targeting_spell != null \
				and _slot_eligible(_targeting_spell.card_instance, slot):
			_slot_chosen.emit(slot)
		return   # ineligible slot — stay in targeting, let the player choose again
	var card := slot.get_card()
	if card == null:
		return
	if _targeting_spell != null and not _eligible(_targeting_spell.card_instance, card.card_instance):
		return   # ineligible pick — stay in targeting, let the player choose again
	_target_chosen.emit(card.card_instance)


# ── Core spell execution ───────────────────────────────────────────────────────

func _execute_spell(card_ui: CardUI, manual_target: CardInstance, manual_slot: SlotUI = null) -> void:
	var inst := card_ui.card_instance
	var cost := inst.get_attribute("cost")
	spell_consumed.emit(card_ui, cost)  # orchestrator deducts mana + removes from hand
	card_ui.queue_free()
	# An ability token acts AS its holder: the effects' source is the unit holding the ability
	# (the rook grants the Barrier), not the ephemeral card-shaped view being consumed.
	var src := inst
	if inst.ability != null and inst.source_building != null:
		src = inst.source_building
	for effect: Effect in inst.data.effects:
		if effect.trigger != Effect.Trigger.ON_PLAY:
			continue
		var ctx := EffectContext.make(src, board.player_grid, board.enemy_grid)
		ctx.manual_target = manual_target
		ctx.manual_slot = manual_slot   # slot-mode extras: the picked slot (may be empty)
		ctx.board_node = board          # + board access for hooks that spawn (see EffectContext)
		ctx.ability = inst.ability      # lets hooks read the ability's parameters
		var results := EffectSystem.apply_single(effect, src, ctx)
		await animator.show_effect_results(results)
		board.cleanup_effect_deaths()
	board.refresh()


func _request_target(spell_ui: CardUI) -> CardInstance:
	if board.get_all_units().is_empty():
		return null
	_is_targeting = true
	_targeting_spell = spell_ui
	board.set_slots_targetable(true, _eligibility_of(spell_ui))
	targeting_started.emit()
	var target: CardInstance = await _target_chosen
	board.set_slots_targetable(false)
	_is_targeting = false
	_targeting_spell = null
	targeting_ended.emit()
	return target


# The slot-mode targeting session (MANUAL_SLOT effects): same shape as _request_target, but
# the pick is a SLOT — eligible empty slots included — resolved via _slot_chosen.
func _request_slot(spell_ui: CardUI) -> SlotUI:
	_is_targeting = true
	_targeting_slot_mode = true
	_targeting_spell = spell_ui
	board.set_slots_targetable_by_slot(true, _slot_eligibility_of(spell_ui))
	targeting_started.emit()
	var slot: SlotUI = await _slot_chosen
	board.set_slots_targetable(false)
	_is_targeting = false
	_targeting_slot_mode = false
	_targeting_spell = null
	targeting_ended.emit()
	return slot


func _can_afford(card_ui: CardUI) -> bool:
	return card_ui.card_instance.get_attribute("cost") <= get_mana.call()


# ── Target eligibility ─────────────────────────────────────────────────────────

# Whether `target` is a valid manual pick for this spell: it must pass the conditions of at
# least one of the spell's manual ON_PLAY effects (a spell with no manual effects has no
# eligibility gate). Keeps the targeting UI honest — only units the resolution would actually
# affect light up and accept the pick, so a spell can't be wasted on an invalid target
# (e.g. Castling onto a unit that already has a Barrier).
func _eligible(spell: CardInstance, target: CardInstance) -> bool:
	var has_manual := false
	for e: Effect in spell.data.effects:
		if e.trigger != Effect.Trigger.ON_PLAY \
				or e.targeting_policy != Effect.TargetingPolicy.MANUAL:
			continue
		has_manual = true
		if EffectSystem.passes_conditions(e.conditions, target):
			return true
	return not has_manual


# The per-occupant predicate handed to CombatBoard.set_slots_targetable.
func _eligibility_of(spell_ui: CardUI) -> Callable:
	return func(occupant: CardInstance) -> bool:
		return _eligible(spell_ui.card_instance, occupant)


# ── Slot-mode eligibility (MANUAL_SLOT effects, e.g. material delivery) ─────────

func _needs_slot(card_ui: CardUI) -> bool:
	return card_ui.card_instance.data.effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY \
			and e.targeting_policy == Effect.TargetingPolicy.MANUAL_SLOT)


# A slot is a valid MANUAL_SLOT pick when it's on the caster's OWN side and is either EMPTY
# (the effect's spawn case) or holds a unit passing the effect's conditions (the merge case).
func _slot_eligible(spell: CardInstance, slot: SlotUI) -> bool:
	if slot.owner_id != 0:
		return false
	var occupant := slot.get_card()
	if occupant == null:
		return true
	for e: Effect in spell.data.effects:
		if e.trigger == Effect.Trigger.ON_PLAY \
				and e.targeting_policy == Effect.TargetingPolicy.MANUAL_SLOT \
				and EffectSystem.passes_conditions(e.conditions, occupant.card_instance):
			return true
	return false


# The per-slot predicate handed to CombatBoard.set_slots_targetable_by_slot.
func _slot_eligibility_of(spell_ui: CardUI) -> Callable:
	return func(slot: SlotUI) -> bool:
		return _slot_eligible(spell_ui.card_instance, slot)
