class_name Unit
extends Card

# A Unit (Core System Design §1): a Card kind bearing the type's fixed machinery — the
# main action, the target poll, the placement baked into its play, and the unit's
# burial effect.
#
# Its stats: the strike pipeline reads `attack` and `speed`, damage lands on `shield`
# first then `health` (Mutation §7); `tapped` is the public mutable tap fact — zero is
# untapped, above zero is tapped, floored at zero by the WriteAuthority (Combat Frame §6).
#
# The built-ins (Core §6; Combat Frame §6, A6):
#   · Placement — a baked-in substantive mutator of the unit's play (A18): the play's
#     resolver elects the slot; the placement mutator moves the holder into it.
#   · Burial — trigger `died` + the route-`target` + is_holder entry (Core §6, A16: the
#     dead unit is died's native target); the burial mutator moves the holder to its
#     side's graveyard. Implied condition removed: death buries wherever it finds the
#     holder (B28).
#   · The main action — trigger `act` + the entry + the baked untapped condition;
#     targeting the attack resolver (enemy units, the attack-preference decision,
#     electing one); payload the tap mutator then the strike. Acting is free: no pay
#     mutator, no engaged pair. The target poll is this resolver's resolve phase.
#
# Move (A3, A9): machinery appoints the Move ability at construction — buildings do not
# receive it, and a building never dodges and is rooted (`is_building`, the envelope's
# birth fact, fixed at construction).

var is_building: bool = false

# The king birth fact (Combat Frame §1, envelope A7): a king's death ends the fight —
# the enemy king's in victory, the player king's in defeat. Stamped by the envelope.
var is_king: bool = false

var main_action: Effect = null


# The type's machinery, built once and shared (Mutation §4's lifecycle).
static var _machinery_templates: Array[Effect] = []
static var _main_action_template: Effect = null


func _init(p_allegiance: Side = null, p_building: bool = false) -> void:
	super._init(p_allegiance)
	is_building = p_building
	effects.append_array(Unit._machinery())
	main_action = Unit._main_action_template
	if not is_building:
		Ability.appoint_move(self)


static func _machinery() -> Array[Effect]:
	if not _machinery_templates.is_empty():
		return _machinery_templates

	var burial_trigger := Trigger.new()
	burial_trigger.event = &"died"
	var burial_entry := Trigger.EntityEntry.new()
	burial_entry.route = &"target"
	burial_entry.conditions.append(IsHolderCondition.new())
	burial_trigger.entity_entries.append(burial_entry)
	var burial_payload: Array[Mutator] = []
	burial_payload.append(BurialMutator.new())
	var burial := Effect.new(burial_trigger, null, burial_payload)
	burial.fielded_condition_removed = true
	_machinery_templates.append(burial)

	var act_trigger := Trigger.new()
	act_trigger.event = &"act"
	act_trigger.entity_entries.append(Ability.source_is_holder())
	var untapped_entry := Trigger.EntityEntry.new()
	untapped_entry.route = &"holder"
	untapped_entry.conditions.append(BakedConditions.Untapped.new())
	act_trigger.entity_entries.append(untapped_entry)
	var attack_conditions: Array[EntityCondition] = []
	attack_conditions.append(IsEnemyCondition.new())
	attack_conditions.append(IsUnitCondition.new())
	var act_payload: Array[Mutator] = []
	act_payload.append(TapMutator.new())
	act_payload.append(StrikeMutator.new())
	_main_action_template = Effect.new(act_trigger,
			TargetResolver.new(attack_conditions, AttackDecision.new()), act_payload)
	# The strike's windup presentation name — the melee approach (the old nearest/leap
	# default). A mint like the procedure cue names (journaled, provisional): the bible
	# names the beat's shape, not this roster.
	_main_action_template.windup_presentation = &"lunge"
	_machinery_templates.append(_main_action_template)
	return _machinery_templates


# The type fact (Core §5): a Unit's play is a manual pick of a Slot — a vacant slot of
# the holder's own side (B28).
func _default_play_targeting() -> TargetResolver:
	var conditions: Array[EntityCondition] = []
	conditions.append(BakedConditions.IsSlot.new())
	conditions.append(IsAllyCondition.new())
	conditions.append(BakedConditions.SlotVacant.new())
	return TargetResolver.new(conditions, HandPickDecision.new())


# The target poll (Core §1; Combat Frame §6): the main action resolver's resolve phase,
# run at interactive idle for the previews — side-effect-free.
func main_action_targets() -> Array[GameEntity]:
	return main_action.resolver.resolve(Plate.new(Event.new(&"act", self, world.game), self))


# The type's baked substantive mutator (Core §6, A18): the placement, first after pay.
func _baked_substantive() -> Array[Mutator]:
	var baked: Array[Mutator] = []
	baked.append(PlacementMutator.new())
	return baked


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append_array([&"attack", &"health", &"max_health", &"speed", &"shield", &"tapped"])
	return out
