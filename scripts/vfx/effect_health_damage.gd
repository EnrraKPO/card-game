class_name VFXEffectHealthDamage
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	# The negative glint owns the card reaction now (grey drain + tremble); a separate red flash
	# would fight the desaturation. Badge glint + number carry the "HP loss" meaning.
	_stat_glint("health", Color(1.0, 0.3, 0.3), false)
	_float_label("-%d" % _event.amount, Color(1.0, 0.3, 0.3), "health")
	queue_free()
