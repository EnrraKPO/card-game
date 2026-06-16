class_name VFXEffectHeal
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	_flash(Color(0.3, 2.0, 0.5))
	_float_label("+%d HP" % _event.amount, Color(0.3, 1.0, 0.4))
	queue_free()
