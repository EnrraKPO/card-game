class_name VFXEffectBuff
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	# Pop the badge itself (the strongest "this stat changed" cue), backed by a focused gain glint
	# on that badge and the magnitude as a rising number — all on the stat, none on the whole card.
	if _event.target.has_method("pulse_stat"):
		_event.target.pulse_stat(_event.attribute, true)
	_stat_glint(_event.attribute, Color(1.0, 0.85, 0.2), true)
	_float_label("+%d" % _event.amount, Color(1.0, 0.85, 0.2), _event.attribute)
	queue_free()
