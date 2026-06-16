class_name VFXEffectCardPlaced
extends VFXEffect

func play() -> void:
	if _event.target == null:
		queue_free(); return
	_event.target.modulate = Color(1.6, 1.6, 0.5)
	var tw := _event.target.create_tween()
	tw.tween_property(_event.target, "modulate", Color.WHITE, 0.3)
	queue_free()
