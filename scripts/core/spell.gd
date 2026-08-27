class_name Spell
extends Card

# A Spell (Core System Design §1, §6): a Card kind. Its machinery: the spell's burial
# effect — trigger `play_engaged` + the source/is_holder entry, a spell is spent by its
# play; resolver electing the holder, fixed in this machinery (Core §6); payload the bury
# mutator, whose BuryRequest targets the recipient.


static var _burial_template: Effect = null


func _init(p_allegiance: Side = null) -> void:
	super._init(p_allegiance)
	if Spell._burial_template == null:
		var burial_trigger := Trigger.new()
		burial_trigger.event = &"play_engaged"
		burial_trigger.entity_entries.append(Ability.source_is_holder())
		var burial_payload: Array[Mutator] = []
		burial_payload.append(BuryMutator.new())
		Spell._burial_template = Effect.new(burial_trigger,
				TargetResolver.new([], HolderDecision.new()), burial_payload)
	effects.append(Spell._burial_template)
