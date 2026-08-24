class_name Spell
extends Card

# A Spell (Core System Design §1, §6): a Card kind. Its machinery: the spell's burial
# effect — trigger `play_engaged` + the source/is_holder entry, a spell is spent by its
# play; the burial mutator moves it to its side's graveyard. A reactor to the burial
# gates on the move's stamped origin housing (Core §2, §6).


static var _burial_template: Effect = null


func _init(p_allegiance: Side = null) -> void:
	super._init(p_allegiance)
	if Spell._burial_template == null:
		var burial_trigger := Trigger.new()
		burial_trigger.event = &"play_engaged"
		burial_trigger.entity_entries.append(Ability.source_is_holder())
		var burial_payload: Array[Mutator] = []
		burial_payload.append(BurialMutator.new())
		Spell._burial_template = Effect.new(burial_trigger, null, burial_payload)
	effects.append(Spell._burial_template)
