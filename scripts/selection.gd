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
# ── The ability sub-pick ──
#
# Abilities are NOT cards, and picking one (aiming it from the inspect tray) must not displace the
# card pick — the card whose panel offered the ability stays the pick throughout. So the pick has
# ONE nested level: the picked card may itself have a picked ability. The nesting is structural,
# not policed: the ability is stored as "the PICK's picked ability", so there is no state in which
# an ability is picked while its owner is not — select_ability makes the owner the pick as part of
# the same declaration, and any write that moves or clears the card pick takes the ability with it
# NOT as a second cleanup step but because "the pick's ability" stops referring to anything the
# moment the pick stops naming its owner.
#
# It does not run the other way: clear_ability backs out of the ability alone and leaves the card
# picked — you un-aimed the ability, not the card.

# Fired only on a REAL change (including to null). A re-check cue for the pull-presentation
# derivers, never a verdict — see CardUI.derive_presentation, which also self-polls.
signal changed(subject: Variant)

var _subject: Variant = null
# The pick's own picked ability — meaningless without _subject, and never survives it (see the
# header). Any Object works as the identity; in combat it's the AbilityData being aimed.
var _ability: Variant = null


func select(subject: Variant) -> void:
	if subject == null:
		clear()
		return
	if _subject == subject:
		return          # already the pick — the gesture happened, the state did not change
	_subject = subject
	_ability = null     # not a cleanup: the NEW pick simply has no picked ability yet
	changed.emit(_subject)


func clear() -> void:
	if _subject == null:
		return
	_subject = null
	_ability = null     # "the pick's ability" no longer refers to anything
	changed.emit(null)


# Declares `ability` (of `owner`) the picked ability. Picking an ability ENTAILS its owner being
# the pick — one declaration, and if the owner already is the pick (the usual case: aimed from its
# own open panel) that half changes nothing at all.
func select_ability(owner: Variant, ability: Variant) -> void:
	select(owner)
	if _ability == ability:
		return
	_ability = ability
	changed.emit(_subject)


# Backs out of the ability alone; the card stays picked (its panel stays open).
func clear_ability() -> void:
	if _ability == null:
		return
	_ability = null
	changed.emit(_subject)


# Whether `subject` IS the pick. The question every view asks about itself.
#
# A freed subject is nobody's pick: screens that rebuild their cards can leave the pick pointing at
# an object that no longer exists, and comparing against a freed instance is an error rather than a
# false. Caught here, once, instead of at every asking site.
func holds(subject: Variant) -> bool:
	if subject == null or _subject == null:
		return false
	if _subject is Object and not is_instance_valid(_subject):
		_subject = null
		return false
	return _subject == subject


# Whether `ability` of `owner` IS the picked ability — the tray widget's question about itself.
# Both halves must hold: the same ability object under a different pick is someone else's.
func ability_held(owner: Variant, ability: Variant) -> bool:
	return holds(owner) and ability != null and _ability == ability


func current() -> Variant:
	return _subject


func current_ability() -> Variant:
	return _ability


func active() -> bool:
	return _subject != null
