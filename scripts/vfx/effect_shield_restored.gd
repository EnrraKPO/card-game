class_name VFXEffectShieldRestored
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	# Glint ONLY — no floating number. Per-turn shield regen fires on every unit at once, so a label
	# here is pure spam; the gain glint on the shield badge is enough to point the eye.
	if _event.amount > 0:
		_stat_glint("shield", Color(0.4, 0.8, 1.0), true)
	queue_free()
