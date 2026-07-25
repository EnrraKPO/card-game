class_name VFXEffectHeal
extends VFXEffect


# Span: the positive glint's bloom to full; the rising number is tail.
func _init() -> void:
	span = 0.26


func play() -> void:
	if _event.target == null:
		queue_free(); return
	_stat_glint("health", Color(0.4, 1.0, 0.5), true)
	_float_label("+%d" % _event.amount, Color(0.3, 1.0, 0.4), "health")
	queue_free()
