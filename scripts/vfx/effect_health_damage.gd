class_name VFXEffectHealthDamage
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	_flash(Color(2.0, 0.3, 0.3))
	_float_label("-%d HP" % _event.amount, Color(1.0, 0.3, 0.3))
	queue_free()
