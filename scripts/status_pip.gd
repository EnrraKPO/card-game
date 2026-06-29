class_name StatusPip
extends Panel

# A status badge shown on a card (built by CardUI._make_status_pip): the coloured glyph/icon +
# count panel, plus a small styled, autowrapped hover tooltip (name, count, description). A thin
# Panel subclass purely so it can override _make_custom_tooltip for a legible wrapped tooltip
# instead of the default single-line one (status descriptions can be a sentence long).

var status: StatusInstance


func setup(si: StatusInstance) -> StatusPip:
	status = si
	# Non-empty tooltip_text is required for Godot to invoke _make_custom_tooltip at all.
	tooltip_text = si.data.display_name
	return self


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
