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


static func install(p_hand: Hand, p_board: CombatBoard, p_interaction: Interaction) -> CombatContext:
	var ctx := CombatContext.new()
	ctx.hand = p_hand
	ctx.board = p_board
	ctx.interaction = p_interaction
	current = ctx
	return ctx


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


# Threat questions delegate to the board, which owns the declared preview world (grids are its
# domain). "Do I menace the pivot?" / "am I the pivot's victim?" — see CombatBoard.
func menaces_pivot(inst: CardInstance) -> bool:
	return board != null and board.menaces_pivot(inst)


func is_pivot_target(inst: CardInstance) -> bool:
	return board != null and board.is_pivot_target(inst)
