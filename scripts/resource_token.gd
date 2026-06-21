class_name ResourceToken
extends PanelContainer

# A draggable representation of a fungible crafting resource (an id in a MaterialBag — see
# Materials). Renders the material's colour + short name + available count, and drags a
# { "type": ResourceToken.PAYLOAD_TYPE, "id": <material id> } payload that DropSlot accepts.
# Purely visual: a token stands for "one of this resource". Staging and spending are the
# MaterialBag's job, driven by the owning artifact (see lab_screen.gd). Reusable beyond the
# Lab — the lab-world foundation, built on Godot's native Control drag-and-drop.

const PAYLOAD_TYPE := "resource"

# Emitted on a tap (a click that wasn't a drag) — the Lab uses it to auto-assign the
# resource into the open artifact's first compatible slot, so dragging is optional.
signal clicked(material_id: String)

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
	custom_minimum_size = Vector2(150, 80) if _compact else Vector2(108, 58)
	var c := Materials.color(material_id)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(c.r, c.g, c.b, 0.20)
	sb.border_color = c
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	add_theme_stylebox_override("panel", sb)

	var draggable := available > 0
	mouse_default_cursor_shape = CURSOR_POINTING_HAND if draggable else CURSOR_ARROW
	modulate = Color.WHITE if draggable else Color(1, 1, 1, 0.4)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(box)

	var name_lbl := Label.new()
	name_lbl.text = Materials.short_name(material_id)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 19 if _compact else 13)
	name_lbl.add_theme_color_override("font_color", c)
	name_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(name_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "x%d" % available
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_lbl.add_theme_font_size_override("font_size", 22 if _compact else 15)
	count_lbl.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(count_lbl)


func _get_drag_data(_at: Vector2) -> Variant:
	if available <= 0:
		return null
	var preview := ResourceToken.new().setup(material_id, available, _compact)
	preview.modulate = Color(1, 1, 1, 0.85)
	set_drag_preview(preview)
	return {"type": PAYLOAD_TYPE, "id": material_id}


# A plain tap (no drag) emits `clicked`. During a drag the release is consumed by the drop
# target, so this only fires for genuine clicks — drag and tap-to-assign coexist.
func _gui_input(event: InputEvent) -> void:
	if available <= 0:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			clicked.emit(material_id)
