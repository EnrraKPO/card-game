class_name VFXEffectBuff
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	_flash(Color(2.0, 1.6, 0.3))
	_float_label("+%d %s" % [_event.amount, _attr_label(_event.attribute)],
		Color(1.0, 0.85, 0.2))
	queue_free()
