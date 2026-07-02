class_name DropSlot
extends PanelContainer

# A drop target on a lab artifact (the Refinery's essence slot, the Forge's piece/stone
# slots). It stages a single resource id (fungible — only the id matters; the count lives in the
# MaterialBag), filtered by `can_accept`, and notifies the owning artifact via `on_changed` so it
# can refresh its preview/affordability. Tapping a filled slot clears it. lab_screen drives both
# tap-to-assign and its own manual drag (calling `stage` on a hit) — no native drag-and-drop here
# (it stole taps on touch). Part of the reusable lab-world foundation.

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
	# Portrait to match the resource art (pieces/stones are tall), so the illustration fills the
	# slot instead of floating in a wide box with big side gaps.
	custom_minimum_size = Vector2(138, 214) if _compact else Vector2(96, 152)
	# Staged art fills the slot (inset by the panel's content margin — see _refresh). It replaces
	# the label entirely when present — no text stacked over the illustration. The label is the
	# empty-slot placeholder. NB: PanelContainer stretches children to its content rect and
	# ignores manual offsets, so the margin must live on the stylebox, not here.
	_art = TextureRect.new()
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
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	# Content margin = the breathing room around the art (PanelContainer insets children by it).
	var pad := 18.0 if _compact else 15.0
	for side in ["left", "right", "top", "bottom"]:
		sb.set("content_margin_" + side, pad)
	if staged_id.is_empty():
		# Empty: a quiet dashed-feeling well that reads as "drop here".
		sb.bg_color = Color(ScreenUI.SURFACE_DEEP, 0.85)
		sb.border_color = ScreenUI.SURFACE_BORDER
		_label.text = slot_label
		_label.add_theme_color_override("font_color", Color(0.60, 0.62, 0.70))
		_set_art(null)
	else:
		# Filled: the same discreet tint the inventory tokens use, with the art front and centre.
		var tint := Materials.frame_tint(staged_id)
		sb.bg_color = Color(tint.r, tint.g, tint.b, 0.14)
		sb.border_color = Color(tint.r, tint.g, tint.b, 0.55)
		var tex := Materials.texture(staged_id)
		_set_art(tex)
		if tex == null:   # fallback for any resource without art: show its name
			_label.text = Materials.short_name(staged_id)
			_label.add_theme_color_override("font_color", Materials.color(staged_id))
	add_theme_stylebox_override("panel", sb)


# Show the staged resource's art filling the slot; the art replaces the label entirely (no
# text stacked over the illustration). With no art the label carries the slot's content.
func _set_art(tex: Texture2D) -> void:
	_art.texture = tex
	_art.visible = tex != null
	_label.visible = tex == null


func _gui_input(event: InputEvent) -> void:
	# Tap/click a filled slot to take the item back out.
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT and not staged_id.is_empty():
		clear()
		on_changed.call()
