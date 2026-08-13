class_name PresentationChannel
extends RefCounted

# The one generic channel (signed EFFECT_PRESENTATION_DESIGN.html, amendment 3): every
# happening outside the windup/contact routing — a dodge's sidestep, a critical's flash,
# a damage number — is simply a visual: something to show, on someone, now, with a
# magnitude when there is one. The committing site TELLS this channel at the moment the
# happening happens; nothing is written down for later re-reading (amendment 2).
#
# The sink is installed by the live fight (Combat wires it to the VFX machinery, where
# the named looks live as data) and is absent everywhere else — silence for simulations
# and headless runs is this ONE gate: a recipient with no on-screen surface, or no sink
# at all, shows nothing. Presentation never asks; it is told.

static var _sink: Callable = Callable()


static func install(sink: Callable) -> void:
	_sink = sink


static func clear() -> void:
	_sink = Callable()


# Tell presentation: show `visual` on `recipient`, with `magnitude` when there is one.
# Fire-and-forget by design (NO TIMING COUPLING, §3): the rules never wait for the show.
static func tell(visual: StringName, recipient: Object, magnitude: int = 0) -> void:
	if _sink.is_valid():
		_sink.call(visual, recipient, magnitude)
