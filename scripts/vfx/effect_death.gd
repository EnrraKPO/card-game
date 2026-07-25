class_name VFXEffectDeath
extends VFXEffect

# ATOMIC (span stays 0): whoever plays this disposes of the card when it returns, so handing off
# early would free the corpse mid-fade. Combat instead paces the DEATH BEAT itself against the
# overlap dial (see Combat._bury) using FADE_DUR as the span, while still awaiting the fade in full
# before the card goes — the two are separate questions.
const FADE_DUR := 0.4

func play() -> void:
	if _event.target == null:
		queue_free(); return
	var tw := _event.target.create_tween()
	tw.tween_property(_event.target, "modulate", Color(0.6, 0.1, 0.1, 0.0), FADE_DUR)
	await tw.finished
	queue_free()
