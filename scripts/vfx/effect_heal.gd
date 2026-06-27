class_name VFXEffectHeal
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	_stat_glint("health", Color(0.4, 1.0, 0.5), true)
	_float_label("+%d" % _event.amount, Color(0.3, 1.0, 0.4), "health")
	queue_free()
