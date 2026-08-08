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
		if manual_slot != null:   # the gesture edge translates the picked slot to coordinates
			ctx.manual_row = manual_slot.location.row
			ctx.manual_col = manual_slot.location.col
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


# ── Legality: does this still DO anything? ─────────────────────────────────────
# The companion of the implicit viability condition (see EffectCondition): that rule decides
# which UNITS an effect may reach, and this one asks what falls out of it — if no effect on the
# card can reach anybody right now, there is no play here to make, and the card is illegal
# rather than merely wasteful. A spell that fizzles is a spell the player paid mana for and got
# nothing from; the refusal has to happen before the cost, not after.
#
# Conservative by construction: an effect counts as a play unless it can be PROVEN inert. A
# CUSTOM hook's payload is opaque code, so it always counts — guessing at it would forbid real
# plays, and a wrongly-forbidden card is a far worse failure than a wasted one.

# A card-shaped view's legality (a hand spell, an ability's tray token). Units are exempt: a
# unit is a BODY, and putting one on the board is a play whatever its ON_PLAY effects would do.
func card_has_a_play(inst: CardInstance) -> bool:
	if inst == null or not inst.is_spell:
		return true
	# An ability token acts AS its holder — the same substitution _execute_spell makes, so the
	# legality question is asked from where the effects would actually resolve.
	var src := inst
	if inst.ability != null and inst.source_building != null:
		src = inst.source_building
	return effects_have_a_play(inst.data.effects, src)


# Whether ANY of this effect set's ON_PLAY effects has a legal application right now. An empty
# set (or one with no ON_PLAY effects at all) is legal: there is nothing to judge, so there is
# nothing to forbid.
func effects_have_a_play(effects: Array, holder: CardInstance) -> bool:
	var judged := false
	for e: Effect in effects:
		if e.trigger != Effect.Trigger.ON_PLAY:
			continue
		judged = true
		if _effect_has_a_play(e, holder):
			return true
	return not judged


func _effect_has_a_play(e: Effect, holder: CardInstance) -> bool:
	if e.kind == Effect.Kind.CUSTOM:
		return true   # opaque payload — never proven inert
	if e.targeting_policy == Effect.TargetingPolicy.MANUAL \
			or e.targeting_policy == Effect.TargetingPolicy.MANUAL_SLOT:
		# A manual effect's legality IS "is there a pick the targeting UI would light up", so it
		# asks the very judge that lights them — one definition for the cue and the legality.
		var one: Array = [e]
		for slots: Array in [board.player_slots, board.enemy_slots]:
			for row: Array in slots:
				for slot: SlotUI in row:
					if effects_target_ok(one, slot):
						return true
		return false
	# Everything else resolves its own targets, through the same socket resolution uses — so a
	# set that would resolve to nobody (every candidate filtered out, viability included) is
	# exactly the set that would have fizzled.
	return not e.targets_resolver().resolve(null, holder, board.make_context(holder)).is_empty()


# ── Target eligibility ─────────────────────────────────────────────────────────

# Whether `target` is a valid manual pick for this effect set: it must pass the conditions of
# at least one manual ON_PLAY effect (a set with no manual effects has no eligibility gate).
# Keeps the targeting UI honest — only units the resolution would actually affect light up and
# accept the pick, so a cast can't be wasted on an invalid target (e.g. Castling onto a unit
# that already has a Barrier). Reached through effects_target_ok, never called directly.
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
# Effects-level like _manual_effects_eligible, for the same reason: the autocast gate judges an
# AbilityData's effects directly, where no spell-shaped token exists to reach through.

func _effects_need_slot(effects: Array) -> bool:
	return effects.any(func(e: Effect) -> bool:
		return e.trigger == Effect.Trigger.ON_PLAY \
			and e.targeting_policy == Effect.TargetingPolicy.MANUAL_SLOT)


# A slot is a valid MANUAL_SLOT pick when it's on the caster's OWN side and is either EMPTY
# (the effect's spawn case) or holds a unit passing the effect's conditions (the merge case).
func _effects_slot_eligible(effects: Array, slot: SlotUI) -> bool:
	if slot.owner_id != 0:
		return false
	var occupant := slot.get_card()
	if occupant == null:
		return true
	for e: Effect in effects:
		if e.trigger == Effect.Trigger.ON_PLAY \
				and e.targeting_policy == Effect.TargetingPolicy.MANUAL_SLOT \
				and EffectSystem.passes_conditions(e.conditions, occupant.card_instance):
			return true
	return false


# THE target judge: is `slot` a legal manual pick for this effect set? Dispatches on the set's
# own targeting policy — MANUAL_SLOT effects judge the SLOT (so an empty own slot is a valid
# pick), everything else judges the OCCUPANT. Every gesture that aims an effect set asks this
# one function: hand spells, tray ability tokens, and the armed-holder autocast drag. Keep it
# that way — the Barracks bug was two judges answering this question differently, so a
# slot-targeting ability read valid from the tray and invalid under the holder drag.
func effects_target_ok(effects: Array, slot: SlotUI) -> bool:
	if _effects_need_slot(effects):
		return _effects_slot_eligible(effects, slot)
	var occupant := slot.get_card()
	if occupant == null:
		return false
	return _manual_effects_eligible(effects, occupant.card_instance)


# ── Autocast (an armed ability fired by dragging its holder onto a target) ──────

# Whether dropping dragged unit `holder` onto `slot` fires its armed autocast ability: armed +
# fielded player unit + payable (untapped if tap-costed, mana affordable) + the slot passes the
# ability's own targeting judgement. That last part is effects_target_ok — the SAME judge the
# tray token asks — so a slot-targeting ability (the Barracks' delivery) is castable through
# both gestures, and only the cost/arming checks live here. Consulted by the AUTOCAST action's
# role predicate (cue + drop gate, via CombatBoard.can_autocast) and again at execution.
func autocast_drop_ok(holder: CardInstance, slot: SlotUI) -> bool:
	if holder == null or holder.owner != 0 or not BoardFacade.is_on_board(board.world, holder):
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
