class_name DropSlot
extends PanelContainer

# A drop target on a lab artifact (the Refinery's essence slot, the Forge's piece/stone
# slots). Accepts ResourceToken drags filtered by `can_accept`, stages a single resource id
# (fungible — only the id matters; the count lives in the MaterialBag), and notifies the
# owning artifact via `on_changed` so it can refresh its preview/affordability. Clicking a
# filled slot clears it. Part of the reusable lab-world foundation.

var slot_label := "Empty"
var staged_id := ""
var can_accept := func(_id: String) -> bool: return true   # set by the artifact
var on_changed := func() -> void: return                   # set by the artifact
var _compact := false

var _label: Label
var _art: TextureRect


# Configures and builds the slot; returns self for one-line construction.
func setup(label: String, compact: bool) -> DropSlot:
	slot_label = label
	_compact = compact
	_build()
	return self


func _build() -> void:
	custom_minimum_size = Vector2(150, 112) if _compact else Vector2(118, 84)
	# Illustrated art for a staged piece, behind the name label (hidden until one is staged).
	_art = TextureRect.new()
	_art.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_art.offset_bottom = -(28 if _compact else 20)   # leave room for the name strip below
	_art.offset_top = 6
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_art.mouse_filter = MOUSE_FILTER_IGNORE
	_art.visible = false
	add_child(_art)
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 19 if _compact else 13)
	_label.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_label)
	_refresh()


func clear() -> void:
	staged_id = ""
	_refresh()


# Stages a resource id if this slot accepts it (used by click-to-assign); returns success.
func stage(id: String) -> bool:
	if not can_accept.call(id):
		return false
	staged_id = id
	_refresh()
	on_changed.call()
	return true


func _refresh() -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2)
	if staged_id.is_empty():
		sb.bg_color = Color(0.12, 0.13, 0.18)
		sb.border_color = Color(0.40, 0.42, 0.50)
		_label.text = slot_label
		_label.add_theme_color_override("font_color", Color(0.60, 0.62, 0.70))
		_set_art(null)
	else:
		var c := Materials.color(staged_id)
		sb.bg_color = Color(c.r, c.g, c.b, 0.25)
		sb.border_color = c
		_label.text = Materials.short_name(staged_id)
		_label.add_theme_color_override("font_color", c)
		_set_art(Materials.texture(staged_id))
	add_theme_stylebox_override("panel", sb)


# Show the staged piece's art (if any) filling the slot, with the name pinned to a bottom
# strip; with no art the label centres in the whole slot as before.
func _set_art(tex: Texture2D) -> void:
	_art.texture = tex
	_art.visible = tex != null
	if tex != null:
		_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	else:
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.get("type", "") == ResourceToken.PAYLOAD_TYPE \
		and can_accept.call(data.get("id", ""))


func _drop_data(_at: Vector2, data: Variant) -> void:
	staged_id = data.get("id", "")
	_refresh()
	on_changed.call()


func _gui_input(event: InputEvent) -> void:
	# Tap/click a filled slot to take the item back out.
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT and not staged_id.is_empty():
		clear()
		on_changed.call()
