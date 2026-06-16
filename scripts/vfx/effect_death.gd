class_name VFXEffectDeath
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	var tw := _event.target.create_tween()
	tw.tween_property(_event.target, "modulate", Color(0.6, 0.1, 0.1, 0.0), 0.4)
	await tw.finished
	queue_free()
