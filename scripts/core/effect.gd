class_name Effect
extends RefCounted

# An effect is a rule of the game (Mutation System Design §2). The machinery's effects
# are the base rules; cards, relics, and statuses add rules on top. Every effect enters
# the flow by one road: its trigger. The triad's parts each answer one question — when
# (the trigger), whom (the resolver), what (the payload) — and hold no flow.
#
# An effect authored without a targeting block falls back to the generic AutoResolver —
# it resolves as the target carried in context, falling back to the Game where none is
# found; the default is fixed at construction (Core §4). The windup and contact
# presentation names are the cues the conductor speaks at steps 2 and 4 (Mutation §11).
#
# Every effect of a unit carries the implied default condition THE HOLDER IS FIELDED —
# housed in a slot's `slotted_unit` (Mutation §2) — which an authored form may
# explicitly remove (the removal's authored syntax is out of frame; the member is the
# machinery's seat for it). The condition binds units; holders that are not units are
# untouched by it.
#
# Stateless immutable like its parts: one instance is shared across card copies and
# simulated worlds; the holder arrives on the plate.

var trigger: Trigger = null
var resolver: TargetResolver = null
var payload: Array[Mutator] = []
var windup_presentation: StringName = &""
var contact_presentation: StringName = &""
var fielded_condition_removed: bool = false


func _init(p_trigger: Trigger, p_resolver: TargetResolver, p_payload: Array[Mutator]) -> void:
	trigger = p_trigger
	resolver = p_resolver if p_resolver != null else AutoResolver.new()
	payload = p_payload


func engages(plate: Plate) -> bool:
	if not fielded_condition_removed and plate.holder is Unit:
		var housing: EntityContainer = plate.holder.housing
		if housing == null or housing.name != &"slotted_unit":
			return false
	return trigger.holds(plate)
