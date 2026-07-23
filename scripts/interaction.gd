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
	changed.emit(null)


# Ends the live action if it's the drag gesture owned by `source` — wired to unit/spell
# drag-ended signals.
func end_drag(source: CardUI) -> void:
	if _action != null and _action.is_drag and _action.source == source:
		end_action(_action)


# The current action's verdict for a slot (NONE when idle) — SlotUI's drop gate asks this.
func role_of(slot: SlotUI) -> int:
	if _action == null:
		return Role.NONE
	return _action.role_of(slot)


# Drop commit: Godot's drag-drop landed on `slot`. Re-validates via the SAME predicate that
# lit the cue, then commits. The action itself ends with the drag (end_drag), not here.
func commit_drop(slot: SlotUI) -> bool:
	if _action == null:
		return false
	var role := role_of(slot)
	if role != Role.DESTINATION and role != Role.TARGET_VALID:
		return false
	_action.commit(slot)
	return true


# Click commit: a slot was pressed while a click session is live. Returns true when the press
# was CONSUMED (committed, or swallowed by a modal session holding out for a valid pick);
# false lets the press fall through to normal handling (inspection, selection switching).
func handle_slot_press(slot: SlotUI) -> bool:
	if _action == null or _action.is_drag:
		return false
	var role := role_of(slot)
	if role == Role.DESTINATION or role == Role.TARGET_VALID:
		var act := _action
		end_action(act)        # cues clear BEFORE resolution/animation, like the old sessions
		act.commit(slot)
		return true
	# An invalid pick during a modal session stays in the session (the old "ineligible pick —
	# stay in targeting, let the player choose again").
	return _action.modal
