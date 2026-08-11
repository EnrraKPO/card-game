extends Node

# THE selection. One value, game-wide: what the player has picked right now, or nothing.
#
# There is no "deselect" — moving the pick from A to B is a single assignment, and A stops being
# picked because the state no longer names it. Nothing is ever told it has been selected or
# deselected: every view that can show a pick CONSULTS this (CardUI.derive_presentation) and
# derives its own answer, so two views of the same subject can never disagree and no view can be
# left lit by a cleanup someone forgot.
#
# Two operations, and only two:
#   Selection.select(subject)   the subject becomes the pick; if it already IS the pick, nothing
#                               happens at all — no signal, no transition, nothing to re-apply
#   Selection.clear()           nothing is picked
#
# That idempotence is the whole point: "select what is already selected" has to be a no-op in the
# STATE, so that no amount of re-clicking can accumulate anything downstream.
#
# The subject is the thing picked, not the widget showing it — a CardInstance for a card (the same
# unit may be drawn by its board card, a tray entry and a sidebar preview at once), any Object for
# widgets that are their own subject (a forge chip). Whoever handles the gesture declares it; that
# is recording game state, not addressing a view.
#
# (The ability sub-pick — a nested "the pick's picked ability" level for aiming from the
# inspect tray — was deleted 2026-08-11: its production callers died with the ability
# costume, and by ruling nothing lives on test life-support. The rebuilt activation
# gesture (TARGETING_DESIGN.md §7) declares its own selection surface.)

# Fired only on a REAL change (including to null). A re-check cue for the pull-presentation
# derivers, never a verdict — see CardUI.derive_presentation, which also self-polls.
signal changed(subject: Variant)

var _subject: Variant = null


func select(subject: Variant) -> void:
	if subject == null:
		clear()
		return
	if _subject == subject:
		return          # already the pick — the gesture happened, the state did not change
	_subject = subject
	changed.emit(_subject)


func clear() -> void:
	if _subject == null:
		return
	_subject = null
	changed.emit(null)


# A freed subject is nobody's pick: screens that rebuild their cards (a unit retiring, a hand
# rebuilt) can leave the pick pointing at an object that no longer exists, and a freed instance
# fails LOUDLY at every use — `==` errors, and `as` throws "Trying to cast a freed object". So the
# collapse happens ONCE, here, on the way out of the state: every reader below funnels through
# this, and none of them can observe a freed pick. Silent by design — no `changed` emission from a
# read. The pick didn't move, it stopped existing, and every view derives (CardUI.derive_presentation
# self-polls) rather than waiting to be told.
#
# `typeof` and NOT `is Object`: `is` DEREFERENCES its left operand, so on a freed instance the
# guard itself errors ("Left operand of 'is' is a previously freed instance") — the check meant to
# absorb the hazard trips over it. typeof reads the Variant's type tag and touches nothing. Nor can
# is_instance_valid stand alone up front: a non-Object pick is legal (deck screens pick bare String
# ids) and would read invalid, collapsing a perfectly live pick.
func _live() -> Variant:
	if typeof(_subject) == TYPE_OBJECT and not is_instance_valid(_subject):
		_subject = null
	return _subject


# Whether `subject` IS the pick. The question every view asks about itself.
func holds(subject: Variant) -> bool:
	if subject == null:
		return false
	return _live() != null and _subject == subject


func current() -> Variant:
	return _live()


func active() -> bool:
	return _live() != null
