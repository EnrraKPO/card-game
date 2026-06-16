class_name VFXEffectShieldRestored
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	_flash(Color(0.4, 0.8, 2.0), 0.5)
	if _event.amount > 0:
		_float_label("+%d SHD" % _event.amount, Color(0.35, 0.75, 1.0))
	queue_free()
