class_name VFXEffectTargetMark
extends VFXEffect

# Played on each card singled out by an effect — the "this one is being affected" cue. A reticle
# frame that snaps INWARD onto the card (the opposite motion to the source glint's outward bloom)
# and is tinted (`_event.color`) by what's happening to it: red damage, green heal, gold buff,
# purple debuff. Fires alongside the effect's own VFX, framing where the player should look.

const MARK_DUR := 0.32


func play() -> void:
	var card := _event.target
	if card == null or not is_instance_valid(card):
		queue_free(); return

	var frame := Panel.new()
	frame.size = card.size
	frame.custom_minimum_size = frame.size
	frame.z_index = 15
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.pivot_offset = frame.size * 0.5
	frame.global_position = card.global_position
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(_event.color, 0.0)
	sb.set_corner_radius_all(14)
	# A quiet frame, not a flood: this only says "look at THIS card" — the stat badge's own pop +
	# glint carry "what changed", and a heavy reticle (especially a gold one over a gold buff) drowns
	# them out. Thin border, faint shadow, sub-full alpha.
	sb.border_color = Color(_event.color, 0.8)
	sb.set_border_width_all(3)
	sb.shadow_color = Color(_event.color, 0.28)
	sb.shadow_size = 5
	sb.anti_aliasing = true
	frame.add_theme_stylebox_override("panel", sb)
	_root.add_child(frame)

	# Snap in from slightly oversized, hold a beat bright, then fade out.
	frame.scale = Vector2(1.12, 1.12)
	var tw := _root.create_tween()
	tw.tween_property(frame, "scale", Vector2.ONE, 0.12).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_interval(0.08)
	tw.tween_property(frame, "modulate:a", 0.0, MARK_DUR - 0.20)
	tw.tween_callback(frame.queue_free)

	queue_free()
