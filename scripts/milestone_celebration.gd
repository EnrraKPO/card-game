class_name MilestoneCelebration
extends Control

# A blocking, celebratory milestone modal — the hub's fanfare for an achievement (see Achievements).
# A dim scrim + a centred panel in the game's palette: a heading, the reward's icon, a line of copy,
# and a Continue button — optionally a "Forge a King in the Lab →" call-to-action that jumps straight
# to the Lab. Modeled on the Lab's own "New King Forged!" reveal (lab_screen._show_king_celebration)
# and SettingsOverlay's mount, so it matches the game's existing celebration look.
#
# Mounted on a high CanvasLayer over the viewport (like SettingsOverlay) rather than nested in the
# host, so its dim covers the whole screen regardless of the host's own margins.

const PANEL_WIDTH := 720.0
const LAB_SCENE := "res://scenes/lab_screen.tscn"

var _layer: CanvasLayer
var _title := ""
var _body := ""
var _icon: Texture2D = null
var _lab_cta := false
var _panel: PanelContainer


# Opens the celebration over `host`'s viewport. `icon` is optional (the reward art). When
# `lab_cta` is true the modal offers a button that dismisses and navigates to the Lab.
static func open(host: Node, title: String, body: String, icon: Texture2D = null,
		lab_cta: bool = false) -> void:
	if host == null or not host.is_inside_tree():
		return
	var modal := MilestoneCelebration.new()
	modal._title = title
	modal._body = body
	modal._icon = icon
	modal._lab_cta = lab_cta
	var layer := CanvasLayer.new()
	layer.layer = 205   # above the settings overlay (200), below a toast (210)
	modal._layer = layer
	layer.add_child(modal)
	host.get_viewport().add_child(layer)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # blocking — the player must acknowledge it

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.8)
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
	style.set_border_width_all(2)
	style.border_color = CardTooltip.BORDER_COLOR
	style.set_corner_radius_all(16)
	style.set_content_margin_all(40)
	style.shadow_color = Color(0, 0, 0, 0.55)
	style.shadow_size = 22
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	var box := VBoxContainer.new()
	box.custom_minimum_size.x = minf(PANEL_WIDTH, get_viewport_rect().size.x * 0.86)
	box.add_theme_constant_override("separation", 22)
	_panel.add_child(box)

	var heading := Label.new()
	heading.text = _title
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 48)
	heading.add_theme_color_override("font_color", Materials.color(Materials.piece_id("king")))
	box.add_child(heading)

	if _icon != null:
		var pic := TextureRect.new()
		pic.texture = _icon
		# EXPAND_IGNORE_SIZE so the large source art doesn't dictate the min size — the fixed box governs.
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Vector2(160, 160)
		pic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(pic)

	var body_lbl := Label.new()
	body_lbl.text = _body
	body_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.add_theme_font_size_override("font_size", 30)
	body_lbl.add_theme_color_override("font_color", CardTooltip.TEXT_MAIN)
	box.add_child(body_lbl)

	box.add_child(_build_buttons())

	Vfx.play("ui_modal_open_bloom", _panel)   # settles in; the cue carries the modal sound
	_animate_in()


func _build_buttons() -> Control:
	# A single Continue when there's no call-to-action; otherwise the Lab jump is the primary
	# action and "Not now" the dismiss.
	if not _lab_cta:
		var cont := ScreenUI.action_button("Continue", _close, Vector2(0, 84), 32,
			ScreenUI.CHROME_CONFIRM)
		cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		return cont

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 14)

	var to_lab := ScreenUI.action_button("Forge a King in the Lab  →", _go_to_lab,
		Vector2(0, 92), 32, ScreenUI.CHROME_CONFIRM)
	to_lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(to_lab)

	var later := ScreenUI.action_button("Not now", _close, Vector2(0, 72), 26,
		ScreenUI.CHROME_NEUTRAL)
	later.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(later)
	return rows


# A quick fade + scale pop so it arrives with a little life (pivot set after first layout).
func _animate_in() -> void:
	modulate.a = 0.0
	await get_tree().process_frame
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2(0.9, 0.9)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "modulate:a", 1.0, 0.2)
	tw.tween_property(_panel, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_OUT)


func _go_to_lab() -> void:
	_close()
	Nav.goto(LAB_SCENE)


func _close() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
