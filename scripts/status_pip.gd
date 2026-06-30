class_name StatusPip
extends Panel

# A status badge shown on a card — the scene status_pip.tscn (size, fonts, corners, borders are all
# authored there; edit the scene to restyle/resize). The script only binds the per-status DATA: its
# colour tint, icon-or-glyph, count and stack numbers. It's a Panel subclass so it can glint as the
# status's container cue (see glint) and show the status's own rich hover tooltip.

var status: StatusInstance


# Binds a live status onto the scene's nodes (called right after instantiate, before it enters the
# tree — so it uses direct child access, not @onready, and the local-to-scene stylebox override).
func setup(si: StatusInstance) -> void:
	status = si
	var sd := si.data
	# Non-empty tooltip_text is required for Godot to invoke _make_custom_tooltip at all.
	tooltip_text = sd.display_name

	# Per-status colour onto the badge fill (the stylebox is local-to-scene, so this is per-instance).
	var sb := get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.bg_color = sd.color

	# Prefer the status's art; fall back to its coloured glyph.
	var art := sd.icon()
	var icon := $Icon as TextureRect
	var glyph := $Glyph as Label
	if art != null:
		icon.texture = art
		icon.visible = true
		glyph.visible = false
	else:
		glyph.text = sd.glyph
		glyph.visible = true
		icon.visible = false

	# Headline count (bottom-right): stack count for a count-decay status, else remaining turns.
	var cnt := si.count()
	var count_lbl := $Count as Label
	count_lbl.text = str(cnt)
	count_lbl.visible = cnt > 0

	# Stack tag (top-left) for a timed status that also stacks intensity (count-decay shows it above).
	var stacks_lbl := $Stacks as Label
	stacks_lbl.text = "x%d" % si.stacks
	stacks_lbl.visible = sd.decay != StatusData.DECAY_STACKS and si.stacks > 1


# Status pips carry TWO distinct, reusable cues — the same vocabulary for every status, so "fired"
# and "gained" always read the same way no matter which status it is:
#   • flash_proc    — the status's triggered effect just FIRED (poison ticked, blind forced a miss…):
#                     a sharp WHITE discharge + scale punch.
#   • flash_applied — the status was just APPLIED/stacked onto the card: a softer bloom in the
#                     status's OWN colour + a gentle pop.
# Both bail if the pip isn't laid out yet (can't pivot from a zero rect).

func flash_proc() -> void:
	if size == Vector2.ZERO:
		return
	pivot_offset = size * 0.5
	_white_flash()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector2(1.55, 1.55), 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.chain().tween_property(self, "scale", Vector2.ONE, 0.22).set_ease(Tween.EASE_OUT)


func flash_applied() -> void:
	if size == Vector2.ZERO:
		return
	pivot_offset = size * 0.5
	_color_ring(status.data.color if status != null else Color.WHITE)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector2(1.28, 1.28), 0.12).set_ease(Tween.EASE_OUT)
	tw.chain().tween_property(self, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)


# A bright white sheen blooming over the pip and fading — the unmistakable "this fired" discharge,
# above the row's clip so it can't be hidden.
func _white_flash() -> void:
	var flash := Panel.new()
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.z_index = 50
	flash.size = size
	flash.pivot_offset = size * 0.5
	var fs := StyleBoxFlat.new()
	fs.bg_color = Color(1, 1, 1, 0.9)
	fs.set_corner_radius_all(8)
	flash.add_theme_stylebox_override("panel", fs)
	add_child(flash)
	var ft := create_tween()
	ft.set_parallel(true)
	ft.tween_property(flash, "scale", Vector2(1.7, 1.7), 0.34).set_ease(Tween.EASE_OUT)
	ft.tween_property(flash, "modulate:a", 0.0, 0.34).set_ease(Tween.EASE_OUT)
	ft.chain().tween_callback(flash.queue_free)


# A hollow ring in `col` ringing outward from the pip and fading — the "gained" bloom, tinted by the
# status so an application reads as arrival, not discharge.
func _color_ring(col: Color) -> void:
	var ring := Panel.new()
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.z_index = 50
	ring.size = size
	ring.pivot_offset = size * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col, 0.0)
	sb.border_color = Color(col, 0.85)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(10)
	sb.anti_aliasing = true
	ring.add_theme_stylebox_override("panel", sb)
	add_child(ring)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(ring, "scale", Vector2(1.95, 1.95), 0.38).set_ease(Tween.EASE_OUT)
	t.tween_property(ring, "modulate:a", 0.0, 0.38)
	t.chain().tween_callback(ring.queue_free)


func _make_custom_tooltip(_for_text: String) -> Object:
	if status == null:
		return null
	var sd: StatusData = status.data
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.14, 0.97)
	style.set_border_width_all(1)
	style.border_color = sd.color
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var cnt := status.count()
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	var icon := sd.icon_rect(24.0)
	if icon != null:
		title_row.add_child(icon)
	var title := Label.new()
	title.text = "%s%s" % [sd.display_name, (" %d" % cnt) if cnt > 0 else ""]
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", sd.color.lightened(0.4))
	title_row.add_child(title)
	vbox.add_child(title_row)

	if not sd.description.is_empty():
		var desc := Label.new()
		desc.text = sd.description
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc.custom_minimum_size.x = 240.0
		desc.add_theme_font_size_override("font_size", 14)
		desc.modulate = Color(0.82, 0.82, 0.9)
		vbox.add_child(desc)

	return panel
