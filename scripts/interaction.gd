class_name Interaction
extends Node

# THE single owner of "what is the player doing right now" in combat. At most one Action is
# live at a time; every gesture (placing/moving a unit, targeting a spell or tray ability,
# aiming an armed autocast) BEGINS an action here and ENDS through here. Presentation
# components (CombatBoard's cue renderer, SlotUI's drop gate, DragGhost verdicts, the Ready
# button, input gating) all derive from the one `changed` signal — so a gesture ending resets
# everything structurally, with no per-path cleanup to forget. See INTERACTION_DESIGN.md.
#
# Actions DECLARE (rules: role_of / commit); components REACT (each maps roles to its own
# visuals in exactly one place). The rules themselves stay with the rules experts — SpellCaster
# builds cast actions, CombatBoard builds unit/autocast actions — this node only runs the
# lifecycle.

signal changed(action: Action)   # null = returned to idle

# What a slot IS under the current action — the shared vocabulary between rules and
# presentation. NONE deliberately differs from TARGET_INVALID: a plain move leaves irrelevant
# slots NEUTRAL (no red X), a targeted cast marks them invalid. Each action's role_of encodes
# that policy.
enum Role { NONE, DESTINATION, TARGET_VALID, TARGET_INVALID }


# A declarative description of one player gesture. Built by the rules experts' factories
# (CombatBoard.make_unit_action / make_autocast_action, SpellCaster.make_cast_action).
class Action:
	extends RefCounted

	enum Kind { UNIT, CAST, CAST_SLOT, AUTOCAST }

	var kind: int = Kind.UNIT
	var source: CardUI = null
	# THE rules authority for this action: func(SlotUI) -> Interaction.Role. Consulted by the
	# board renderer (cue per slot), the slot drop gate, AND commit-time re-validation — one
	# predicate, so cue / drop-accept / execution can never disagree.
	var role_check: Callable
	# func(SlotUI) -> void. Performs the action on a chosen slot (drop or click — same entry).
	# May be async (spell resolution awaits); fired without awaiting.
	var on_commit: Callable
	# Optional func() -> void, called once when the action ends (deselect visuals, etc.).
	var on_end: Callable
	var animated: bool = false     # drag (bobbing cues) vs static selection presentation
	var is_drag: bool = false      # drag-owned (ends with the drag) vs click session
	# Click sessions only: a modal session (spell/tray targeting) captures EVERY slot press —
	# an invalid pick keeps the session alive instead of falling through to inspection. A
	# non-modal session (a selected unit's static cues) lets presses on other slots switch the
	# selection as normal.
	var modal: bool = false
	# Click sessions only: whether a press on a valid slot COMMITS. Placement from hand does
	# (pick a card, tap a spot); repositioning a fielded unit deliberately does NOT — a unit
	# already on the board moves by DRAG alone, so a stray tap can never rearrange the line the
	# player just built. The commit path itself is untouched (the drag uses the same action and
	# the same predicate); only the click entry is closed.
	var click_commit: bool = true
	# The fielded unit whose attack projection (crosshair + incoming-threat glow) shows while
	# this action is live; null = no preview (hand cards aren't on the board yet).
	var preview_instance: CardInstance = null

	func role_of(slot: SlotUI) -> int:
		if role_check.is_valid():
			return role_check.call(slot)
		return Interaction.Role.NONE

	func commit(slot: SlotUI) -> void:
		if on_commit.is_valid():
			on_commit.call(slot)


var _action: Action = null


func active() -> bool:
	return _action != null


# A modal click session (spell/tray targeting) is live — the state most "don't interfere"
# guards care about (the old SpellCaster.is_targeting()).
func modal_active() -> bool:
	return _action != null and _action.modal


func current() -> Action:
	return _action


func begin(action: Action) -> void:
	if action == _action:
		return
	var prev := _action
	_action = action
	if prev != null and prev.on_end.is_valid():
		prev.on_end.call()
	# Aiming IS picking — declared here, where every gesture begins, rather than by each caster.
	# But what gets picked depends on what is being aimed: a SPELL is a card, so it becomes the
	# pick; a tray ABILITY is not a card — aiming it picks the ability OF its holder, which keeps
	# the holder the pick (and its inspect panel open) for the whole aim. Idempotent either way: a
	# gesture begun on what the player had already picked changes nothing at all.
	if action != null and action.modal and action.source != null:
		var inst := action.source.card_instance
		if inst != null and inst.ability != null and inst.source_building != null:
			Selection.select_ability(inst.source_building, inst.ability)
		else:
			Selection.select(inst)
	changed.emit(_action)


# Ends the current action (idempotent). Pass `only` to end conditionally — a stale drag-end
# arriving after a new action began must not kill the newcomer.
func end_action(only: Action = null) -> void:
	if _action == null:
		return
	if only != null and only != _action:
		return
	var prev := _action
	_action = null
	if prev.on_end.is_valid():
		prev.on_end.call()
	# The aim's pick ends with the aim — at the level the aim picked. An ability aim backs out of
	# the ABILITY alone (its holder stays the pick, panel open); a spell aim clears the card pick.
	# Guarded so a pick that already moved on (the aim resolved into a new selection) is left be.
	if prev.modal and prev.source != null and prev.source.card_instance != null:
		var inst := prev.source.card_instance
		if inst.ability != null and inst.source_building != null:
			if Selection.ability_held(inst.source_building, inst.ability):
				Selection.clear_ability()
		elif Selection.holds(inst):
			Selection.clear()
	changed.emit(null)


# Ends the live action if it's the drag gesture owned by `source` — wired to unit/spell
# drag-ended signals.
func end_drag(source: CardUI) -> void:
	if _action != null and _action.is_drag and _action.source == source:
		end_action(_action)


# The current action's verdict for a slot (NONE when idle) — cue rendering and hover ask this.
func role_of(slot: SlotUI) -> int:
	if _action == null:
		return Role.NONE
	return _action.role_of(slot)


# Whether `dragged` is the card the live action is actually about. Godot's drag-drop asks the
# control under the CURSOR, and hands it the payload — it has no idea which gesture is live, so
# nothing downstream can assume the two agree. They diverge for real: a modal click session
# (SpellCaster._on_spell_card_pressed) stays live while another card is picked up, and that
# card's drag deliberately begins no action of its own (_on_spell_drag_started early-returns).
# Without this check the drop gate would answer for the SESSION's card, so dropping card B
# spent card A — the wrong ability consumed, resolved wherever B happened to land.
# EVERY drag-drop path must pass the payload through here; role_of alone is not a gate.
func owns_drag(dragged: Variant) -> bool:
	return _action != null and dragged is CardUI and dragged == _action.source


# Drop commit: Godot's drag-drop landed on `slot`. Re-validates via the SAME predicate that
# lit the cue, then commits. The action ENDS HERE, before committing — same order as the click
# path (handle_slot_press): a move reparents the dragged card, and reparenting the node that
# started the drag eats its NOTIFICATION_DRAG_END, so end_drag would never fire and the gesture's
# preview (menace/crosshair cues) would strand. Ending here doesn't rely on that notification.
# end_action is idempotent, so a DRAG_END that does still arrive is a harmless no-op.
# `dragged` is Godot's drop payload: the commit is refused unless it IS this action's source
# (see owns_drag). The gate is repeated here rather than trusted from _can_drop_data because the
# two are separate queries at separate moments — the same reason the role is re-validated.
func commit_drop(slot: SlotUI, dragged: Variant) -> bool:
	if _action == null or not owns_drag(dragged):
		return false
	var role := role_of(slot)
	if role != Role.DESTINATION and role != Role.TARGET_VALID:
		return false
	var act := _action
	end_action(act)
	act.commit(slot)
	return true


# Press commit for a click session, bypassing the click_commit gate — the entry the slot's
# MOVE BUTTON uses: click_commit stays false for a fielded unit (a stray tap on the slot still
# never moves it), while the button — an explicit control that exists only to commit — goes
# through here. Same end-then-commit order as drops and clicks, same role re-validation.
func commit_press(slot: SlotUI) -> bool:
	if _action == null or _action.is_drag:
		return false
	var role := role_of(slot)
	if role != Role.DESTINATION and role != Role.TARGET_VALID:
		return false
	var act := _action
	end_action(act)        # cues clear BEFORE resolution/animation, like the old sessions
	act.commit(slot)
	return true


# Click commit: a slot was pressed while a click session is live. Returns true when the press
# was CONSUMED (committed, or swallowed by a modal session holding out for a valid pick);
# false lets the press fall through to normal handling (inspection, selection switching).
func handle_slot_press(slot: SlotUI) -> bool:
	if _action == null or _action.is_drag:
		return false
	if _action.click_commit and commit_press(slot):
		return true
	# An invalid pick during a modal session stays in the session (the old "ineligible pick —
	# stay in targeting, let the player choose again").
	return _action.modal
