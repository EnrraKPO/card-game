class_name EffectConductor
extends RefCounted

# The owner of what running one effect means (Mutation System Design §11). The triad's
# parts each answer one question — when, whom, what — and hold no flow; the conductor
# asks them in order and tells presentation between the steps. It is built by the
# cascade from the world alone; presentation is reached through the world's outlet.
#
# The run, exactly: (1) engage the target resolution — unknowns settle here, in the live
# flow; an empty election ends the delivery, and for an activated ask that refuses the
# ask before payment, the pay mutator never speaking. (2) Cue the windup. (3) Pause the
# presenter and deliver: first the payload's unique mutators, once each, recipient null;
# then per-mutator-then-per-recipient — the payload list is the authored sequence, so
# its order dominates: each mutator speaks its full ask across all recipients before the
# next begins. Requests flow to the engine as they are issued; events travel by return
# into the delivery's holster. (4) Cue the contact — the presenter unpauses here, the
# held cues play. (5) Cue the conclusion. Every cue is awaited: blocking lives here, in
# the flow layer — never in the engine.
#
var _world_ref: WeakRef = null


func _init(world: World) -> void:
	_world_ref = weakref(world)


func run(effect: Effect, plate: Plate, holster: Array[Event]) -> void:
	var world: World = _world_ref.get_ref()
	var targets: Array[GameEntity] = await effect.resolver.engage(plate)
	if targets.is_empty():
		return
	await world.outlet.windup(effect.windup_presentation, plate.holder, targets)
	world.outlet.pause()
	for mutator: Mutator in effect.payload:
		if mutator.is_unique():
			holster.append_array(mutator.issue(plate, null))
	for mutator: Mutator in effect.payload:
		if mutator.is_unique():
			continue
		for recipient: GameEntity in targets:
			holster.append_array(mutator.issue(plate, recipient))
	await world.outlet.contact(effect.contact_presentation, plate.holder, targets)
	world.outlet.unpause()
	await world.outlet.conclude(effect.windup_presentation, plate.holder)
