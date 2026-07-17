class_name VFXEffectCrit
extends VFXEffect

# Played when an attack lands as a CRITICAL (the speed-driven damage spike in Resolver._submit).
# Unlike a dodge or a miss, real damage still lands — so this cue sits ALONGSIDE the normal
# shield/health damage numbers, never replacing them: a hot red-orange "Critical!" label pops
# off the victim while the ordinary "-N" readouts do their usual work. The attacker-side half
# of the cue (the Speed badge glint — speed is what drove the crit) fires at the combat call
# site, since this event only knows the card being hit.

const CRIT_COLOR := Color(1.0, 0.42, 0.24)   # hot red-orange — escalation, distinct from the
											 # cyan of Dodge and the grey of Miss


func play() -> void:
	var card := _event.target
	if card == null or not is_instance_valid(card):
		queue_free(); return
	_float_label("Critical!", CRIT_COLOR, "")
	queue_free()
