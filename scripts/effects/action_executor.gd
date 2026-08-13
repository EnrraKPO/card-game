class_name ActionExecutor
extends RefCounted

# The one piece of machinery that RUNS an action once its trigger (or, later, its cost
# gate) says yes (signed ATTACK_SYSTEM_DESIGN.html §3): it asks the TargetResolver for
# the resolution, assembles the Feed per recipient, and walks the payloads. It is the
# only party that ever holds all four facts at once — which is exactly why the feeding
# job is its. Nothing is returned (the outcome is ruled out of existence — signed
# EFFECT_PRESENTATION_DESIGN.html amendment 2): every mutation announces itself at its
# own commit.
#
# THE GUARD (signed §6): this executor never inspects what a payload or mutator IS — it
# only serves the plate. Species logic leaking in here is how the old dispatcher grew;
# any such leak is a design violation, not a refactor.

# Run a triggered effect that already passed its trigger gate: resolve, then deliver.
static func run(effect: TriggeredEffect, event: GameEvent, holder: CardInstance,
		world: CombatWorld, owner: int = TriggerResolver.OWNER_FROM_HOLDER) -> void:
	var anchor := TriggerResolver.anchor_owner(holder, owner)
	var recipients: Array = []
	if effect.targets == null:
		recipients = [null]
	else:
		recipients = effect.targets.resolve(world, holder, anchor)
	deliver(effect, event, holder, world, recipients, anchor)


# Deliver a resolution already taken (the read happened at the trigger moment; a caller
# that presents between resolution and delivery — the attack's approach cue — hands the
# same resolution back in). Payload-major order: each payload lands on every recipient of
# the ONE shared resolution before the next payload starts ("deal 3 to X and stun IT"
# lands as authored). A targetless effect delivers once with a null recipient (the
# payload names its own recipient — side payloads, when they return). An empty resolution
# delivers nothing — a legal whiff, not an error.
static func deliver(effect: TriggeredEffect, event: GameEvent, holder: CardInstance,
		world: CombatWorld, recipients: Array,
		owner: int = TriggerResolver.OWNER_FROM_HOLDER) -> void:
	var anchor := TriggerResolver.anchor_owner(holder, owner)
	for payload: Payload in effect.payloads:
		for recipient: Variant in recipients:
			var feed := Feed.make(world, holder, anchor, event, recipient as GameEntity)
			if payload.applies(feed):
				payload.deliver(feed)
