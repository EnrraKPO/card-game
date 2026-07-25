class_name CombatContext
extends RefCounted

# The DECLARED combat state that cards CONSULT — never are told. Which card is selected, which
# instance is inspected, and the preview world (the pivot standing at a hypothetical spot) that
# threat questions are answered in. One per combat: Combat installs `current` on entry and
# clears it on exit, so on every other screen `current` is null and card derivations no-op —
# non-combat card views keep their own presentation untouched.
#
# Cards re-derive from this on cues (existing signals, routed by Combat as "re-check now"
# hints carrying no verdict), on reparent, and on their slow self-poll — so a missed cue
# self-corrects within a beat, and a stale caller can never produce a wrong state. See
# CardUI.derive_presentation and INTERACTION_DESIGN.md.

static var current: CombatContext = null

var hand: Hand = null
var board: CombatBoard = null
var interaction: Interaction = null
var side: CombatSide = null   # the PLAYER's side — the resource facts affordability derives from


static func install(p_hand: Hand, p_board: CombatBoard, p_interaction: Interaction,
		p_side: CombatSide) -> CombatContext:
	var ctx := CombatContext.new()
	ctx.hand = p_hand
	ctx.board = p_board
	ctx.interaction = p_interaction
	ctx.side = p_side
	current = ctx
	return ctx


# Live player mana — the one resource fact every affordability question asks. Consulted, so a
# view can answer "can I be paid for right now?" without anyone pushing the answer at it.
func player_mana() -> int:
	return side.mana if side != null else 0


# Whether an ability is castable RIGHT NOW (see AbilityData.usable_by).
func ability_usable(holder: CardInstance, ab: AbilityData) -> bool:
	return ab != null and ab.usable_by(holder, player_mana())


static func clear() -> void:
	current = null


# Selected = the hand's declared selection, OR the source card of a modal aiming session
# (a spell/token being click-aimed reads as selected for the session's duration — previously
# a push+cleanup pair in SpellCaster, now just this read).
func is_selected(card: CardUI) -> bool:
	if hand != null and hand.selected() == card:
		return true
	return interaction != null and interaction.modal_active() \
			and interaction.current().source == card


func inspected_instance() -> CardInstance:
	return hand.inspected_instance() if hand != null else null


# ── Stand-ins: where a unit is REALLY being drawn right now ───────────────────────
# A lunging attacker never leaves its slot — a ghost duplicate does the travelling while the real
# card is concealed in place. So during a strike "which view IS this unit?" has two answers, and
# BOTH of them are consulted here rather than pushed:
#
#   • the VFX layer asks stand_in_for(), so a cue about the attacker (its on-attack glint, a Speed
#     badge flashing on a crit) plays on the card the player is actually watching;
#   • the concealed original asks is_concealed() on its own derivation and hides itself.
#
# Declaring the stand-in is therefore THE WHOLE of hiding the source — there is no second step, and
# no window in which the two can disagree. Hiding used to be an alpha poke at the original card, and
# the pull-presentation appliers (set_exhausted / set_selected, both writing `modulate` wholesale)
# silently republished it at full opacity on the next re-derive — so the unit appeared to clone
# itself beside its own ghost instead of flying out of its slot.
var _stand_in: Dictionary = {}   # CardInstance -> CardUI


func declare_stand_in(inst: CardInstance, view: CardUI) -> void:
	if inst == null or view == null:
		return
	_stand_in[inst] = view


func clear_stand_in(inst: CardInstance) -> void:
	_stand_in.erase(inst)


# The unit's travelling view, or null if it is being drawn in its own slot. Freed views read as
# absent, so a stand-in that was torn down without its entry being erased self-heals rather than
# leaving a unit invisible forever.
func stand_in_for(inst: CardInstance) -> CardUI:
	var view := _stand_in.get(inst) as CardUI
	return view if view != null and is_instance_valid(view) else null


func is_concealed(inst: CardInstance) -> bool:
	return stand_in_for(inst) != null


# Threat questions delegate to the board, which owns the declared preview world (grids are its
# domain). "Do I menace the pivot?" / "am I the pivot's victim?" — see CombatBoard.
func menaces_pivot(inst: CardInstance) -> bool:
	return board != null and board.menaces_pivot(inst)


func is_pivot_target(inst: CardInstance) -> bool:
	return board != null and board.is_pivot_target(inst)


# The other party in every threat exchange — see CombatBoard.pivot.
func pivot() -> CardInstance:
	return board.pivot() if board != null else null
