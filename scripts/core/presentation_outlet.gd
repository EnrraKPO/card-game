class_name PresentationOutlet
extends RefCounted

# The world's presentation outlet (Mutation System Design §10). A procedure issues its cue
# on the spot, at commit — named visual, recipient, magnitude, plus one optional variant
# (e.g. buff effects routing to different stats) — fire-and-forget,
# synchronous, never awaited; the engine never waits. The live world bears the presenter
# behind this surface (Phase 5); a simulated world bears this base as-is: deaf — it
# receives everything and plays nothing.
#
# Reception is unconditional; playback is gated: the conductor pauses the outlet before
# engaging a payload and unpauses at the contact cue, and what pausing means to playback
# is the presenter's business — the deaf base has none.

func cue(_visual: StringName, _recipient: GameEntity, _magnitude: float,
		_variant: StringName = &"") -> void:
	pass


func pause() -> void:
	pass


func unpause() -> void:
	pass


# ── The conductor's flow beats (Mutation §11, source per A12) ─────────────────────────
# Unlike the procedures' fire-and-forget cue above, every flow beat is AWAITED: the flow
# proceeds when presentation greenlights it, and any VFX determines the span of its
# block. Coroutines by contract; the deaf base greenlights on the spot. Each beat carries
# the acting holder (AMENDMENTS.html A12) so the presenter can play the cause half of a
# happening — the source's glint, the lunge, the bolt from actor to victim.

func windup(_visual: StringName, _source: GameEntity,
		_recipients: Array[GameEntity]) -> void:
	@warning_ignore("redundant_await")
	await null


func contact(_visual: StringName, _source: GameEntity,
		_recipients: Array[GameEntity]) -> void:
	@warning_ignore("redundant_await")
	await null


func conclude(_visual: StringName, _source: GameEntity) -> void:
	@warning_ignore("redundant_await")
	await null
