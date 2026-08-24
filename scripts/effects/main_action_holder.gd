class_name MainActionHolder
extends RefCounted

# THE one piece of main-action machinery on the unit (signed MAIN_ACTION_DESIGN.html §4):
# the single authority on "what this unit does", with the three ruled duties:
#
#   1. FIRE ON ACT — when the unit acts, the appointed main action fires. The appointment
#      — never an authored trigger — binds the action to the act event at runtime, and
#      gates its firing on UNTAPPED (amendment 3): a tapped unit's main action does not
#      fire. The attack files stopped authoring that rule; it lives here.
#   2. ANSWER THE TARGET POLL — "who are my main action's current targets?" (§5):
#      answered internally — the action consults its own target resolver, the resolver
#      answers against the world that owns the unit — and the answer is ENTITIES ONLY.
#      No effect-shaped object, no resolver, nothing with readable insides ever crosses
#      outward (the effects-are-sealed charter).
#   3. THE ENTRY POINT FOR SWITCHES — when main actions become switchable at runtime,
#      the switch lands on this holder and nowhere else. Its semantics are §8's open
#      question, deferred by ruling to its own future cycle; only the entry point is
#      ruled, so nothing else about switching exists here.
#
# The main action is a RUNTIME FACT under the auto-appointment rule (§4): a unit with
# exactly one action needs no ceremony — that action is immediately its main action.
# No per-unit stamp is authored anywhere at this scope.
#
# The unit reference is weak: the unit owns its holder, and a strong back-reference
# would cycle two RefCounteds into a leak.

var _unit_ref: WeakRef = null


static func make(unit: CardInstance) -> MainActionHolder:
	var h := MainActionHolder.new()
	h._unit_ref = weakref(unit)
	return h


func _unit() -> CardInstance:
	return (_unit_ref.get_ref() as CardInstance) if _unit_ref != null else null


# THE APPOINTMENT, auto-appointed (§4): the unit's one Action-kind effect. Appointability
# flows from the trigger kind alone (amendment 3) — no flag, no further spec. A card
# authoring more than one action is a caught mistake at this scope: no per-unit stamp
# exists to say which is active until multi-action cards do — reported loudly, the first
# stays appointed (deterministic, never silent).
func main_action() -> TriggeredEffect:
	var unit := _unit()
	if unit == null or unit.data == null:
		return null
	var appointed: TriggeredEffect = null
	for e: TriggeredEffect in unit.data.effects:
		if e.trigger is TriggerResolver.Action:
			if appointed != null:
				push_error("MainActionHolder: '%s' authors more than one action — no per-unit stamp exists at this scope (MAIN_ACTION_DESIGN.html §4); the first stays appointed" % unit.data.id)
				break
			appointed = e
	return appointed


# Duty 1's gate: the effect to fire at this event, or null. Only the unit's OWN act
# moment fires the appointment, and the appointment carries the untapped rule.
func action_for(event: GameEvent) -> TriggeredEffect:
	var unit := _unit()
	if unit == null or event == null or event.id != &"act" or event.origin != unit:
		return null
	if unit.attack_exhausted:
		return null
	return main_action()


# Duty 2's inner answering (§5): the holder consults the main action, the action consults
# its own target resolver, and the resolver answers against the world that owns the unit
# (TARGETING_DESIGN.md §3: resolver instances are owned by a CombatWorld and query it) —
# never a world the poller chose. Computed fresh at every read (this poll IS the
# interactive-idle read moment); never stored. Empty is a real answer: no appointment,
# a targetless action, or a unit standing in no world all answer "nobody".
func targets() -> Array[LegacyGameEntity]:
	var nobody: Array[LegacyGameEntity] = []
	var unit := _unit()
	var action := main_action()
	if unit == null or action == null or action.targets == null:
		return nobody
	var world := unit.world()
	if world == null:
		return nobody
	return action.targets.resolve(world, unit)
