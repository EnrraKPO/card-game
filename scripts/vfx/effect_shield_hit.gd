class_name VFXEffectShieldHit
extends VFXEffect

# y_offset staggers the label above health damage when both fire simultaneously
func play() -> void:
	if _event.target == null:
		queue_free(); return
	_flash(Color(0.3, 0.65, 2.0))
	_float_label("-%d SHD" % _event.amount, Color(0.35, 0.75, 1.0), -18.0)
	queue_free()
