class_name VFXEffectDebuff
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	# Dip the badge itself (the strongest "this stat changed" cue), backed by a focused loss glint
	# that snaps inward on that badge, plus the magnitude — all on the stat, none on the whole card.
	if _event.target.has_method("pulse_stat"):
		_event.target.pulse_stat(_event.attribute, false)
	_stat_glint(_event.attribute, Color(0.78, 0.42, 1.0), false)
	_float_label("-%d" % _event.amount, Color(0.75, 0.4, 1.0), _event.attribute)
	queue_free()
