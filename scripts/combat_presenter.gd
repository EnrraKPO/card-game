class_name CombatPresenter
extends RefCounted

# The cascade's complete presentation surface (COMBAT_DECOUPLING_REFACTOR.md Step 2): every
# way the rules of "what happens when an effect fires" touch the screen, as one injected
# interface. The cascade declares WHAT happened; a presenter decides what that looks like
# and how long it takes.
#
# THIS BASE CLASS IS THE NULL PRESENTER. Every method returns without suspending, and
# GDScript's await is pay-per-suspend — awaiting a call that never yields falls straight
# through, same stack, same frame. Hand a cascade this object and the identical code that
# animates a live fight runs synchronously to completion in one call: the system ALLOWS
# waiting, it never FORCES it. Simulations construct one of these; live combat constructs
# a LivePresenter.
#
# The surface grows with the refactor's phases — the attack loop's choreography (lunges,
# interception cues, dodge/crit beats) joins when that loop gets its seam. Methods exist
# here only once a cascade call site routes through them; no speculative interface.


# One dispatched group of effect results, shown from its holder's perspective (card glint /
# status-pip glint, then the results' cues) — the cascade's "dispatch shows its results by
# construction" moment. Mirrors CombatAnimator.show_effect_results.
func show_effect_results(_results: Array, _holder: CardInstance, _status_id: String = "",
		_cue: bool = true) -> void:
	pass


# A relic's run-level proc: glint the owner's tray chip, then hold the chip's beat so the
# proc reads as cause -> effect. One composite (glint + beat) so "no tray, no beat" stays
# a presentation decision.
func relic_glint(_owner_id: String) -> void:
	pass


# A pacing pause of `seconds`, subject to the live presenter's overlap dial (Vfx.handoff).
# The cascade hands over the RAW span; how much of it actually elapses is presentation.
func beat(_seconds: float) -> void:
	pass


# The enemy King's send-off: the fall, the blast, the treasure chest thrown clear. Awaited
# in full by the live fight because the chest gates the end of combat. The presenter finds
# the corpse's card itself — the unit has already left play (world.retire) but its card is
# still standing in its slot.
func king_fall(_inst: CardInstance) -> void:
	pass


# A unit's corpse fading where it stood, plus the death beat the fight pauses for. The fade
# itself deliberately outlives the beat (the live presenter starts it un-awaited).
func unit_fade(_inst: CardInstance) -> void:
	pass


# One phase moment's GROUND procs, batched board-wide: each entry {slot, status_id, results}.
# Presented as ONE beat — every acting tab glints at once and the results land together (the
# whole fire acts as one; contrast show_ground_spread_roll, where each flame acts alone).
# See SLOT_LAYER_DESIGN.md.
func show_ground_results(_procs: Array) -> void:
	pass


# One spread-tier ROLL (CombatCascade._spread_ground): `slot`'s `stack_index`-th tab of
# `status_id` just rolled, with `outcome` &"spread" (a stack leapt to `target`), &"fade"
# (that flame died down) or &"hold" (nothing). The rolling glint is identical for every
# outcome — the target's ignition flare is the only success signal.
func show_ground_spread_roll(_slot: BoardSlot, _status_id: String, _stack_index: int,
		_outcome: StringName, _target: BoardSlot) -> void:
	pass


# The board view re-deriving itself after a phase moment's dust settles.
func board_refresh() -> void:
	pass
