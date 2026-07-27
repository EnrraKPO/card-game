class_name ConfirmOverlay
extends Control

# THE "are you sure?" surface for any screen — one yes/no question, in the game's own art style.
# Modeled on SettingsOverlay (scrim + centred CardTooltip-palette panel + GlossyButtons) for the
# same reason it is: a native ConfirmationDialog can't take the game look and renders thumb-hostile
# on a phone. Screens that need a decision confirmed should reach for this rather than growing
# their own scrim-and-two-buttons, so every irreversible action in the game asks the same way.
#
#   ConfirmOverlay.ask(self, "Title", "Body copy", func(): do_it())
#
# The confirm callback fires only on the confirm button; dismissing (Cancel, Esc, OS back, or a
# click on the scrim) always resolves to NO. That asymmetry is the point: this exists to guard
# actions that can't be undone, so every ambiguous exit has to mean "don't".

const PANEL_WIDTH := 960.0

var _layer: CanvasLayer
var _panel: PanelContainer
var _title := ""
var _body := ""
var _confirm_label := ""
var _cancel_label := ""
var _on_confirm: Callable
var _resolved := false

signal closed(confirmed: bool)


# Opens the question over `host`'s viewport. `on_confirm` runs only if the player confirms.
# Labels default to the shared common.* strings. Returns the overlay (null if host isn't mounted)
# so a caller can also connect `closed` for the NO case.
static func ask(host: Node, title: String, body: String, on_confirm: Callable,
		confirm_label: String = "", cancel_label: String = "") -> ConfirmOverlay:
	if host == null or not host.is_inside_tree():
		return null
	var overlay := ConfirmOverlay.new()
	overlay._title = title
	overlay._body = body
	overlay._on_confirm = on_confirm
	overlay._confirm_label = confirm_label if confirm_label != "" else Loc.t("common.confirm")
	overlay._cancel_label = cancel_label if cancel_label != "" else Loc.t("common.cancel")
	var layer := CanvasLayer.new()
	layer.layer = 200
	overlay._layer = layer
	layer.add_child(overlay)
	host.get_viewport().add_child(layer)
	return overlay


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.66)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_resolve(false))
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

	var inner := VBoxContainer.new()
	inner.custom_minimum_size.x = minf(PANEL_WIDTH, get_viewport_rect().size.x * 0.86)
	inner.add_theme_constant_override("separation", 34)
	_panel.add_child(inner)

	var title_lbl := Label.new()
	title_lbl.text = _title
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 48)
	title_lbl.add_theme_color_override("font_color", CardTooltip.TEXT_TITLE)
	inner.add_child(title_lbl)

	var body_lbl := Label.new()
	body_lbl.text = _body
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body_lbl.add_theme_font_size_override("font_size", 30)
	body_lbl.add_theme_color_override("font_color", CardTooltip.TEXT_MAIN)
	inner.add_child(body_lbl)

	# Cancel sits FIRST and wears the neutral chrome: the safe answer should be the one a thumb
	# reaches by habit, and the destructive one should take a deliberate press.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	inner.add_child(row)

	var cancel := ScreenUI.action_button(_cancel_label, func() -> void: _resolve(false),
			Vector2(0, 96), 32, ScreenUI.CHROME_NEUTRAL)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cancel)

	var ok := ScreenUI.action_button(_confirm_label, func() -> void: _resolve(true),
			Vector2(0, 96), 32, ScreenUI.CHROME_CONFIRM)
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ok)

	Vfx.play("ui_modal_open_bloom", _panel)   # settles in; the cue carries the modal sound


# Esc / OS back resolve to NO, like every other ambiguous exit.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_resolve(false)


# Single exit point — guarded so a double-click (or Esc landing on the same frame as a press)
# can't run the action twice or emit two answers.
func _resolve(confirmed: bool) -> void:
	if _resolved:
		return
	_resolved = true
	if confirmed and _on_confirm.is_valid():
		_on_confirm.call()
	closed.emit(confirmed)
	if _layer != null:
		_layer.queue_free()
		_layer = null
