class_name SettingsOverlay
extends Control

# The player settings overlay — opened by the header's ⚙ gear (Shell wires it). A Control
# overlay in the game's own art style (modeled on RelicInspector: scrim + centred dark
# CardTooltip-palette panel, GlossyButtons), NOT a native dialog — native windows can't take
# the game look and render tiny on phones. Everything is deliberately HUGE: this is a
# thumb-first surface.
#
# Two mixer rows (Music / SFX), each a big Mute toggle + a fat 0–100% slider driving
# AudioSettings live — you hear the level while dragging, there is no Apply step.

const PANEL_WIDTH := 860.0
const SLIDER_HEIGHT := 84.0

var _layer: CanvasLayer
var _panel: PanelContainer


static func open(host: Node) -> void:
	if host == null or not host.is_inside_tree():
		return
	var overlay := SettingsOverlay.new()
	var layer := CanvasLayer.new()
	layer.layer = 200
	overlay._layer = layer
	layer.add_child(overlay)
	host.get_viewport().add_child(layer)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.66)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CardTooltip.BG_COLOR
	style.set_border_width_all(1)
	style.border_color = CardTooltip.BORDER_COLOR
	style.set_corner_radius_all(10)
	style.set_content_margin_all(44)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	_fill_panel()
	Vfx.play("ui_modal_open_bloom", _panel)   # settles in; the cue carries the modal sound


# Builds the panel's contents. Kept separate from _ready so a language switch can rebuild it
# in place (this overlay is code-built, so re-picking the locale means re-emitting the copy).
func _fill_panel() -> void:
	var inner := VBoxContainer.new()
	# Full design width where it fits, else shrink to the screen (portrait phones) — the rows
	# are containers, so everything inside tracks the narrower panel.
	inner.custom_minimum_size.x = minf(PANEL_WIDTH, get_viewport_rect().size.x * 0.86)
	inner.add_theme_constant_override("separation", 30)
	_panel.add_child(inner)

	var title := Label.new()
	title.text = Loc.t("settings.title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", CardTooltip.TEXT_TITLE)
	inner.add_child(title)

	inner.add_child(_language_row())
	inner.add_child(_mixer_row(Loc.t("settings.music"), "music"))
	inner.add_child(_mixer_row(Loc.t("settings.sfx"), "sfx"))

	var done := ScreenUI.action_button(Loc.t("settings.done"), _close, Vector2(0, 96), 34)
	done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(done)


# Swaps the whole panel body for the newly-selected language (Loc has already switched).
func _rebuild() -> void:
	for child in _panel.get_children():
		_panel.remove_child(child)
		child.queue_free()
	_fill_panel()


# The language picker: one big highlighted button per shipped language (the active one wears
# the confirm chrome). Picking a new one flips the locale and rebuilds the panel in place.
func _language_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)

	var name_lbl := Label.new()
	name_lbl.text = Loc.t("settings.language")
	name_lbl.add_theme_font_size_override("font_size", 40)
	name_lbl.add_theme_color_override("font_color", CardTooltip.TEXT_MAIN)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_lbl)

	for lang: String in Loc.LANGS:
		var active := Loc.locale() == lang
		var btn := ScreenUI.action_button(Loc.language_name(lang), Callable(), Vector2(220, 84), 28,
			ScreenUI.CHROME_CONFIRM if active else ScreenUI.CHROME_NEUTRAL)
		if not active:
			var pick := lang
			btn.pressed.connect(func() -> void:
				Loc.set_locale(pick)
				_rebuild())
		row.add_child(btn)
	return row


func _mixer_row(label_text: String, kind: String) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 24)
	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.add_theme_font_size_override("font_size", 40)
	name_lbl.add_theme_color_override("font_color", CardTooltip.TEXT_MAIN)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(name_lbl)

	# Mute is a GlossyButton toggle (the game has no native-checkbox look anywhere) — pressed
	# = muted, and its face says the state outright rather than relying on a tick mark.
	var mute := ScreenUI.action_button("", Callable(), Vector2(220, 84), 28,
		ScreenUI.CHROME_DANGER if AudioSettings.muted(kind) else ScreenUI.CHROME_NEUTRAL)
	mute.toggle_mode = true
	mute.button_pressed = AudioSettings.muted(kind)
	mute.text = Loc.t("settings.muted") if AudioSettings.muted(kind) else Loc.t("settings.mute")
	mute.toggled.connect(func(on: bool) -> void:
		AudioSettings.set_muted(kind, on)
		mute.text = Loc.t("settings.muted") if on else Loc.t("settings.mute")
		mute.base_color = ScreenUI.CHROME_DANGER if on else ScreenUI.CHROME_NEUTRAL)
	top.add_child(mute)
	row.add_child(top)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 24)
	var slider := _big_slider()
	slider.value = AudioSettings.volume(kind) * 100.0
	var pct_lbl := Label.new()
	pct_lbl.custom_minimum_size.x = 130
	pct_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pct_lbl.add_theme_font_size_override("font_size", 40)
	pct_lbl.add_theme_color_override("font_color", CardTooltip.TEXT_TITLE)
	pct_lbl.text = "%d%%" % roundi(slider.value)
	slider.value_changed.connect(func(v: float) -> void:
		AudioSettings.set_volume(kind, v / 100.0)
		pct_lbl.text = "%d%%" % roundi(v))
	bottom.add_child(slider)
	bottom.add_child(pct_lbl)
	row.add_child(bottom)
	return row


# A finger-sized slider in the game's palette: fat rounded groove, filled portion in the
# chrome accent, and a big round grabber (a radial-gradient disc — no asset needed).
func _big_slider() -> HSlider:
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0, SLIDER_HEIGHT)

	var groove := StyleBoxFlat.new()
	groove.bg_color = Color(0.16, 0.17, 0.24)
	groove.set_border_width_all(1)
	groove.border_color = CardTooltip.BORDER_COLOR
	groove.set_corner_radius_all(12)
	groove.content_margin_top = 12.0
	groove.content_margin_bottom = 12.0
	slider.add_theme_stylebox_override("slider", groove)

	var filled := StyleBoxFlat.new()
	filled.bg_color = Color(0.52, 0.56, 0.78)
	filled.set_corner_radius_all(12)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled)

	var disc := GradientTexture2D.new()
	disc.width = 56
	disc.height = 56
	disc.fill = GradientTexture2D.FILL_RADIAL
	disc.fill_from = Vector2(0.5, 0.5)
	disc.fill_to = Vector2(0.5, 0.0)
	var grad := Gradient.new()
	var ink := Color(0.95, 0.94, 0.9)
	grad.offsets = PackedFloat32Array([0.0, 0.8, 0.88, 1.0])
	grad.colors = PackedColorArray([ink, ink, Color(ink, 0.0), Color(ink, 0.0)])
	disc.gradient = grad
	slider.add_theme_icon_override("grabber", disc)
	slider.add_theme_icon_override("grabber_highlight", disc)
	slider.add_theme_icon_override("grabber_disabled", disc)
	return slider


func _close() -> void:
	if _layer != null:
		_layer.queue_free()


# A press on the scrim (outside the panel) dismisses; presses inside the panel belong to the
# controls (slider drags must never close the overlay).
func _input(event: InputEvent) -> void:
	var is_press := (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
	if not is_press:
		return
	var pos: Vector2 = (event as InputEventMouseButton).position if event is InputEventMouseButton \
		else (event as InputEventScreenTouch).position
	if not _panel.get_global_rect().has_point(pos):
		get_viewport().set_input_as_handled()
		_close()
