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
# A cast has FULLY resolved — hand spell, tray ability token or autocast alike. The await chain
# inside a cast is the only thing that knows when it has finished, and a cast can end the fight
# (a fire spell on the captain), so the orchestrator asks its own question here — see
# Combat._settle_if_decided. Nothing about spell RULES hangs off this; it is a "done" wire.
signal cast_resolved

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


# "Is this unit a piece standing on the field?" — asked of the board, which is the only thing
# that knows (see LocationManager). No board, or a board with no world, means no field to
# stand on: false, rather than a crash. A gesture gate must never be the thing that takes the
# game down.
func _is_fielded(inst: CardInstance) -> bool:
	return board != null and BoardFacade.is_on_board(board.world, inst)


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
	var effects: Array = card_ui.card_instance.data.effects
	var slot_mode := _effects_need_slot(effects)
	act.kind = Interaction.Action.Kind.CAST_SLOT if slot_mode else Interaction.Action.Kind.CAST
	act.role_check = func(slot: SlotUI) -> int:
		if effects_target_ok(effects, slot):
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
	cast_resolved.emit()


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
		if manual_slot != null:   # the gesture edge hands the picked slot's address over whole
			ctx.manual_at = manual_slot.location
		ctx.ability = ab
		var results := EffectSystem.apply_single(effect, src, ctx)
		# Passing `src` glints the ability's holder (see VFXPlayer.play_results) — safe for a
		# regular non-ability spell too, since its `src` is the ephemeral spell card itself
		# (never on the board), which play_results's own fielded-guard already skips.
		await animator.show_effect_results(results, src)
		board.cleanup_effect_deaths()


# Whether this view may cast RIGHT NOW: mana covers the cost, the view itself says it's
# activatable (an ability widget consults its holder's tap state — see CardUI.castable_now),
# AND the thing it would cast still has something to do (see effects_have_a_play).
# The token's non-mana costs used to be gated by simply not wiring an unusable widget, which
# only held for as long as the tray's build-time verdict stayed true; asking the view keeps
# the gate honest for the whole life of the widget.
func _can_afford(card_ui: CardUI) -> bool:
	return card_ui.castable_now() \
			and card_ui.card_instance.get_attribute("cost") <= get_mana.call() \
			and card_has_a_play(card_ui.card_instance)


# ── Legality & eligibility — TARGETING REMOVED (targeting-cleanup demolition) ──
# The judge layer that stood here was SpellCaster's own hand-rolled half of targeting, and it
# is demolished WITH targeting rather than kept as a second authority. What it answered, which
# the rebuilt targeting authority must answer instead (asked, not re-derived here):
#
#   · LEGALITY — "does this card still have a play?" If no effect on a spell can reach anybody
#     right now, the card is ILLEGAL, not merely wasteful: the refusal happens before the mana
#     is paid, never after (the prohibit-non-ops rule's user-facing half). Conservative by
#     construction: an effect counts as a play unless PROVEN inert (a CUSTOM hook's payload is
#     opaque code — it always counts). Units are exempt: a body is a play whatever its ON_PLAY
#     effects would do. An empty set / no ON_PLAY effects = legal (nothing to judge).
#   · GESTURE REQUIREMENT — "does this effect set need a pick, and of what species?" (a unit,
#     or a SQUARE — the slot-mode/material-delivery flow, where an EMPTY own-side square is a
#     valid pick meaning "spawn here"). The old code classified via targeting_policy enum
#     peeks; the rebuilt kinds must DECLARE their requirement instead.
#   · PICK ELIGIBILITY — "is this slot/unit a legal pick?" Only units the resolution would
#     actually affect may light up and accept the drop (e.g. Castling refuses a unit that
#     already has a Barrier); a slot pick must be on the caster's OWN side (a RULE the old
#     code kept only here, in the UI layer — the authority must own it). ONE judge for every
#     gesture — hand spell, tray token, armed-holder autocast drag: the Barracks bug was two
#     judges answering differently. And eligibility must be THE SAME evaluation resolution
#     uses (the old split evaluated conditions with a different allegiance anchor than
#     resolution — the latent disagreement TECH_DEBT_BRIEF.md §"one dispatch" records).
#
# Demolition stubs: no legal picks exist (spells cannot be aimed), while cards themselves stay
# "legal" so hands remain interactive. Everything downstream treats these as the one judge.

func card_has_a_play(_inst: CardInstance) -> bool:
	return true


func effects_have_a_play(_effects: Array, _holder: CardInstance) -> bool:
	return true


func _effects_need_slot(_effects: Array) -> bool:
	return false


func effects_target_ok(_effects: Array, _slot: SlotUI) -> bool:
	return false


# ── Autocast (an armed ability fired by dragging its holder onto a target) ──────

# Whether dropping dragged unit `holder` onto `slot` fires its armed autocast ability: armed +
# fielded player unit + payable (untapped if tap-costed, mana affordable) + the slot passes the
# ability's own targeting judgement. That last part is effects_target_ok — the SAME judge the
# tray token asks — so a slot-targeting ability (the Barracks' delivery) is castable through
# both gestures, and only the cost/arming checks live here. Consulted by the AUTOCAST action's
# role predicate (cue + drop gate, via CombatBoard.can_autocast) and again at execution.
func autocast_drop_ok(holder: CardInstance, slot: SlotUI) -> bool:
	if holder == null or holder.owner != 0 or not _is_fielded(holder):
		return false
	var ab := holder.armed_autocast()
	if ab == null:
		return false
	if ab.tap and holder.attack_exhausted:
		return false
	if ab.mana > get_mana.call():
		return false
	return effects_target_ok(ab.effects, slot)


# Resolves the armed ability on the picked slot, with the HOLDER as effect source (same rule as
# the tray-token path). Slot-mode abilities pass the slot itself, so an EMPTY pick still carries
# a target — the same manual_target/manual_slot pair _execute_spell hands down. Emits
# ability_autocast first so the orchestrator pays the costs — mirroring the consume-then-resolve
# order there.
func activate_autocast(holder: CardInstance, slot: SlotUI) -> void:
	if not autocast_drop_ok(holder, slot):
		return
	var ab := holder.armed_autocast()
	var occupant := slot.get_card()
	var slot_mode := _effects_need_slot(ab.effects)
	ability_autocast.emit(holder, ab)
	await _resolve_on_play(ab.effects, holder, ab,
			occupant.card_instance if occupant != null else null,
			slot if slot_mode else null)
	board.refresh()
	cast_resolved.emit()
