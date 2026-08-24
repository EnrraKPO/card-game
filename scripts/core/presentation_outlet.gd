class_name PresentationOutlet
extends RefCounted

# The world's presentation outlet (Mutation System Design §10). A procedure issues its cue
# on the spot, at commit — named visual, recipient, magnitude — fire-and-forget,
# synchronous, never awaited; the engine never waits. The live world bears the presenter
# behind this surface (Phase 5); a simulated world bears this base as-is: deaf — it
# receives everything and plays nothing.
#
# Reception is unconditional; playback is gated: the conductor pauses the outlet before
# engaging a payload and unpauses at the contact cue, and what pausing means to playback
# is the presenter's business — the deaf base has none.

func cue(_visual: StringName, _recipient: GameEntity, _magnitude: float) -> void:
	pass


func pause() -> void:
	pass


func unpause() -> void:
	pass
