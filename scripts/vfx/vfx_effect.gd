class_name VFXEffect
extends Node

var _event: VFXEvent
var _root:  Node


func setup(event: VFXEvent, root: Node) -> void:
	_event = event
	_root  = root


# Override in subclasses. May use `await` internally to block the caller.
func play() -> void:
	queue_free()


# ── Shared helpers ─────────────────────────────────────────────────────────────

func _float_label(text: String, color: Color, y_offset: float = 0.0) -> void:
	if _event.target == null or not is_instance_valid(_event.target):
		return
	var lbl := Label.new()
	lbl.text    = text
	lbl.modulate = color
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.z_index = 15
	var base_pos := _event.target.global_position \
		+ Vector2(_event.target.size.x * 0.5 - 20.0, y_offset)
	lbl.position = base_pos
	_root.add_child(lbl)
	var tw := _root.create_tween()
	tw.tween_property(lbl, "position:y", base_pos.y - 60.0, 0.7)
	tw.parallel().tween_property(lbl, "modulate:a", 0.0, 0.7)
	tw.tween_callback(lbl.queue_free)


func _flash(flash_color: Color, duration: float = 0.35) -> void:
	if _event.target == null or not is_instance_valid(_event.target):
		return
	var tw := _event.target.create_tween()
	tw.tween_property(_event.target, "modulate", flash_color, duration * 0.25)
	tw.tween_property(_event.target, "modulate", Color.WHITE, duration * 0.75)


func _attr_label(attr: String) -> String:
	match attr:
		"attack":     return "ATK"
		"speed":      return "SPD"
		"max_health": return "Max HP"
		"shield":     return "SHD"
		"health":     return "HP"
		_:            return attr.to_upper()
