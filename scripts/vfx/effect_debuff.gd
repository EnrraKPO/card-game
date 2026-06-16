class_name VFXEffectDebuff
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	_flash(Color(0.8, 0.3, 1.5))
	_float_label("-%d %s" % [_event.amount, _attr_label(_event.attribute)],
		Color(0.75, 0.4, 1.0))
	queue_free()
