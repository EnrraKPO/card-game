class_name SpellCaster
extends Node

# The SPELL-RULES expert: eligibility, execution and costs for spells, tray ability tokens and
# autocast activations. It owns NO gesture state — aiming a spell is an Interaction action
# (built by make_cast_action below); the session lifecycle, cue rendering, drop gating and
# click routing all live with Interaction/CombatBoard. See INTERACTION_DESIGN.md.

signal spell_consumed(card_ui: CardUI, mana_cost: int)
# An armed autocast ability is about to resolve (holder dropped onto a valid target); the
# orchestrator pays its costs (mana + tap) — the tray-token flow's spell_consumed equivalent.
signal ability_autocast(holder: CardInstance, ab: AbilityData)

var board: CombatBoard
var animator: CombatAnimator
var get_mana: Callable  # func() -> int
var interaction: Interaction


func setup(p_board: CombatBoard, p_animator: CombatAnimator, p_get_mana: Callable,
		p_interaction: Interaction) -> void:
	board       = p_board
	animator    = p_animator
	get_mana    = p_get_mana
	interaction = p_interaction


# ── Spell input → Interaction actions ──────────────────────────────────────────

func wire_spell_card(ui: CardUI) -> void:
	ui.pressed.connect(func(): _on_spell_card_pressed(ui))
	ui.spell_drag_started.connect(_on_spell_drag_started)
	ui.spell_drag_ended.connect(_on_spell_drag_ended)


# Click: begins a MODAL aiming session (the board captures presses until a valid pick or a
# cancel). Pressing the spell already being aimed toggles the session off.
func _on_spell_card_pressed(card_ui: CardUI) -> void:
	if interaction.modal_active():
		if interaction.current().source == card_ui:
			interaction.end_action()
		return
	if not _can_afford(card_ui):
		return
	interaction.begin(make_cast_action(card_ui, false))


# Drag: the same action in drag form (non-modal — it lives and dies with the drag). A live
# click session keeps the board; the drag ghost still travels but changes nothing.
func _on_spell_drag_started(card_ui: CardUI) -> void:
	if interaction.modal_active():
		return
	interaction.begin(make_cast_action(card_ui, true))


func _on_spell_drag_ended(card_ui: CardUI) -> void:
	interaction.end_drag(card_ui)


# The cast action: ONE description covering hand spells and tray ability tokens, click and
# drag. Occupant-targeted spells judge slots by their occupant; MANUAL_SLOT spells (material
# delivery) judge the SLOT itself, so eligible EMPTY own slots are valid picks (the spawn
# case). Commit re-validates affordability and resolves — the exact checks the old drop/press
# handlers ran, now downstream of the same predicate that lit the cues.
func make_cast_action(card_ui: CardUI, is_drag: bool) -> Interaction.Action:
	var act := Interaction.Action.new()
	act.source = card_ui
	act.is_drag = is_drag
	act.modal = not is_drag
	var slot_mode := _needs_slot(card_ui)
	act.kind = Interaction.Action.Kind.CAST_SLOT if slot_mode else Interaction.Action.Kind.CAST
	if slot_mode:
		act.role_check = func(slot: SlotUI) -> int:
			if _slot_eligible(card_ui.card_instance, slot):
				return Interaction.Role.TARGET_VALID
			return Interaction.Role.TARGET_INVALID
	else:
		act.role_check = func(slot: SlotUI) -> int:
			var occ := slot.get_card()
			if occ != null and _eligible(card_ui.card_instance, occ.card_instance):
				return Interaction.Role.TARGET_VALID
			return Interaction.Role.TARGET_INVALID
	act.on_commit = func(slot: SlotUI) -> void:
		if not _can_afford(card_ui):
			return
		var occ := slot.get_card()
		await _execute_spell(card_ui,
				occ.card_instance if occ != null else null,
				slot if slot_mode else null)
	# No selection push here: a modal session's source DERIVES its selected tint from the
	# session itself (CombatContext.is_selected) — beginning/ending the session is the whole
	# story, with no set/clear pair to keep symmetric.
	return act


# ── Core spell execution ───────────────────────────────────────────────────────

func _execute_spell(card_ui: CardUI, manual_target: CardInstance, manual_slot: SlotUI = null) -> void:
	var inst := card_ui.card_instance
	var cost := inst.get_attribute("cost")
	# An ability token acts AS its holder: the effects' source is the unit holding the ability
	# (the rook grants the Barrier), not the ephemeral card-shaped view being consumed. Resolved
	# BEFORE emitting spell_consumed below: that signal's handler (Combat._on_spell_consumed →
	# _consume_generated_token → CardUI.clear_generated) nulls inst.source_building synchronously,
	# so reading it after the emit silently loses the holder (breaking both effect source
	# attribution and the activation glint, which depends on src being a real placed unit).
	var src := inst
	if inst.ability != null and inst.source_building != null:
		src = inst.source_building
	spell_consumed.emit(card_ui, cost)  # orchestrator deducts mana + removes from hand
	card_ui.queue_free()
	await _resolve_on_play(inst.data.effects, src, inst.ability, manual_target, manual_slot)
	board.refresh()


# The ON_PLAY resolution loop shared by spell/token casts and autocast activations: build a
# context per effect, apply, animate, sweep deaths. `ab` (nullable) lets hooks read the
# ability's parameters (ctx.ability).
func _resolve_on_play(effects: Array, src: CardInstance, ab: AbilityData,
		manual_target: CardInstance, manual_slot: SlotUI) -> void:
	for effect: Effect in effects:
		if effect.trigger != Effect.Trigger.ON_PLAY:
			continue
		var ctx := board.make_context(src)
		ctx.manual_target = manual_target
		ctx.manual_slot = manual_slot   # slot-mode extras: the picked slot (may be empty)
		ctx.board_node = board          # + board access for hooks that spawn (see EffectContext)
		ctx.ability = ab
		var results := EffectSystem.apply_single(effect, src, ctx)
		# Passing `src` glints the ability's holder (see VFXPlayer.play_results) — safe for a
		# regular non-ability spell too, since its `src` is the ephemeral spell card itself
		# (row == -1, never on the board), which play_results's own row-guard already skips.
		await animator.show_effect_results(results, src)
		board.cleanup_effect_deaths()


func _can_afford(card_ui: CardUI) -> bool:
	return card_ui.card_instance.get_attribute("cost") <= get_mana.call()


# ── Target eligibility ─────────────────────────────────────────────────────────

# Whether `target` is a valid manual pick for this spell: it must pass the conditions of at
# least one of the spell's manual ON_PLAY effects (a spell with no manual effects has no
# eligibility gate). Keeps the targeting UI honest — only units the resolution would actually
# affect light up and accept the pick, so a spell can't be wasted on an invalid target
# (e.g. Castling onto a unit that already has a Barrier).
func _eligible(spell: CardInstance, target: CardInstance) -> bool:
	return _manual_effects_eligible(spell.data.effects, target)


# The effects-level form of _eligible, shared with the autocast gate (which judges an
# AbilityData's effects directly — no spell-shaped token exists on that path).
func _manual_effects_eligible(effects: Array, target: CardInstance) -> bool:
	var has_manual := false
	for e: Effect in effects:
		if e.trigger != Effect.Trigger.ON_PLAY \
				or e.targeting_policy != Effect.TargetingPolicy.MANUAL:
			continue
		has_manual = true
		if EffectSystem.passes_conditions(e.conditions, target):
			return true
	return not has_manual


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


# ── Autocast (an armed ability fired by dragging its holder onto a target) ──────

# Whether dropping dragged unit `holder` onto `slot` fires its armed autocast ability:
# armed + fielded player unit + payable (untapped if tap-costed, mana affordable) + the
# occupant passes the ability's manual-effect conditions. Consulted by the AUTOCAST action's
# role predicate (cue + drop gate, via CombatBoard.can_autocast) and again at execution.
func autocast_drop_ok(holder: CardInstance, slot: SlotUI) -> bool:
	if holder == null or holder.row < 0 or holder.owner != 0:
		return false
	var ab := holder.armed_autocast()
	if ab == null:
		return false
	if ab.tap and holder.attack_exhausted:
		return false
	if ab.mana > get_mana.call():
		return false
	var occupant := slot.get_card()
	if occupant == null:
		return false
	return _manual_effects_eligible(ab.effects, occupant.card_instance)


# Resolves the armed ability on the slot's occupant, with the HOLDER as effect source (same
# rule as the tray-token path). Emits ability_autocast first so the orchestrator pays the
# costs — mirroring _execute_spell's consume-then-resolve order.
func activate_autocast(holder: CardInstance, slot: SlotUI) -> void:
	if not autocast_drop_ok(holder, slot):
		return
	var ab := holder.armed_autocast()
	var target: CardInstance = slot.get_card().card_instance
	ability_autocast.emit(holder, ab)
	await _resolve_on_play(ab.effects, holder, ab, target, null)
	board.refresh()
