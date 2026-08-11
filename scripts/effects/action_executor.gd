class_name ActionExecutor
extends RefCounted

# The one piece of machinery that RUNS an action once its trigger (or, later, its cost
# gate) says yes (signed ATTACK_SYSTEM_DESIGN.html §3): it asks the TargetResolver for
# the resolution, assembles the Feed per recipient, walks the payloads, and returns the
# Outcomes for presentation. It is the only party that ever holds all four facts at once
# — which is exactly why the feeding job is its.
#
# THE GUARD (signed §6): this executor never inspects what a payload or mutator IS — it
# only serves the plate. Species logic leaking in here is how the old dispatcher grew;
# any such leak is a design violation, not a refactor.

# Run a triggered effect that already passed its trigger gate. Payload-major order: each
# payload lands on every recipient of the ONE shared resolution before the next payload
# starts ("deal 3 to X and stun IT" lands as authored). A targetless effect delivers
# once with a null recipient (the payload names its own recipient — side payloads, when
# they return). An empty resolution delivers nothing — a legal whiff, not an error.
static func run(effect: TriggeredEffect, event: GameEvent, holder: CardInstance,
		world: CombatWorld, owner: int = TriggerResolver.OWNER_FROM_HOLDER) -> Array:
	var anchor := TriggerResolver.anchor_owner(holder, owner)
	var recipients: Array = []
	if effect.targets == null:
		recipients = [null]
	else:
		recipients = effect.targets.resolve(world, holder, anchor)
	var outcomes: Array = []
	for payload: Payload in effect.payloads:
		for recipient: Variant in recipients:
			var feed := Feed.make(world, holder, anchor, event, recipient as GameEntity)
			if payload.applies(feed):
				outcomes.append_array(payload.deliver(feed))
	return outcomes
