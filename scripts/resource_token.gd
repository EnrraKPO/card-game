class_name ResourceToken
extends PanelContainer

# A representation of a fungible crafting resource (an id in a MaterialBag — see Materials).
# Renders the material's colour + short name + available count. It does NOT use Godot's native
# drag-and-drop: that grabs the gesture on the tiniest finger drift, which made taps unreliable on
# touch. Instead it just reports the PRESS via `grab`; lab_screen.gd owns the gesture and decides
# tap (assign to the first open slot) vs drag (manual follower → drop on a slot). See DropSlot.

# Emitted when the token is pressed (available only). lab_screen turns this into a tap or a drag.
signal grab(material_id: String)

var material_id := ""
var available := 0
var _compact := false


# Configures and builds the token; returns self for one-line construction.
func setup(id: String, count: int, compact: bool) -> ResourceToken:
	material_id = id
	available = count
	_compact = compact
	_build()
	return self


func _build() -> void:
	var c := Materials.color(material_id)
	var art := Materials.texture(material_id)
	# Illustrated piece tokens are taller and squarer so the art reads big; text resources
	# (essences/stones) keep the compact wide chip.
	if art != null:
		custom_minimum_size = Vector2(150, 186) if _compact else Vector2(104, 128)
	else:
		custom_minimum_size = Vector2(196, 116) if _compact else Vector2(140, 80)

	# Discreet framing: a faint translucent backing, no outline — the art (or label) carries the
	# identity, the panel just gives it a subtle resting place. See Materials.frame_tint for the
	# colour rule (elemental tint for essences/stones + the King, neutral for the other pieces).
	var tint := Materials.frame_tint(material_id)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(tint.r, tint.g, tint.b, 0.10)
	sb.set_corner_radius_all(8)
	# Inset the content so the art/label doesn't kiss the frame edges (more headroom on top).
	sb.content_margin_top = 10
	sb.content_margin_bottom = 6
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	add_theme_stylebox_override("panel", sb)

	var draggable := available > 0
	mouse_default_cursor_shape = CURSOR_POINTING_HAND if draggable else CURSOR_ARROW
	modulate = Color.WHITE if draggable else Color(1, 1, 1, 0.4)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(box)

	# Illustrated tokens (chess pieces) show their art with the name in the tooltip; resources
	# without art (essences/stones) fall back to a coloured name label.
	if art != null:
		tooltip_text = Materials.display_name(material_id)
		var icon := TextureRect.new()
		icon.texture = art
		# Fill the token (minus the count strip) and keep aspect; IGNORE_SIZE so the full-res
		# art doesn't dictate the token's min size (it was blowing the container out).
		icon.size_flags_vertical = SIZE_EXPAND_FILL
		icon.custom_minimum_size = Vector2(0, 118 if _compact else 78)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = MOUSE_FILTER_IGNORE
		box.add_child(icon)
	else:
		var name_lbl := Label.new()
		name_lbl.text = Materials.short_name(material_id)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.add_theme_font_size_override("font_size", 22 if _compact else 17)
		name_lbl.add_theme_color_override("font_color", c)
		name_lbl.mouse_filter = MOUSE_FILTER_IGNORE
		box.add_child(name_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "x%d" % available
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_lbl.add_theme_font_size_override("font_size", 24 if _compact else 18)
	count_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(count_lbl)


# Report the press (only when we actually have some of this resource). We accept the event so the
# surrounding ScrollContainer can't treat a press-and-drag on a token as a scroll. lab_screen then
# distinguishes tap vs drag by how far the pointer moves before release.
func _gui_input(event: InputEvent) -> void:
	if available <= 0:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			grab.emit(material_id)
			accept_event()
