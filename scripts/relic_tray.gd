class_name RelicTray
extends HBoxContainer

# A compact inline strip of the run's relics, designed to live INSIDE the top bar (no row of its
# own — mobile screen space is tight). Layout: a "X/Y" slot count, then a small coloured chip per
# owned relic. Hovering a chip describes its effect. Used interactive in the map HUD (tap a chip to
# discard — see RunData.discard_relic) and read-only in combat. Rebuilt on entry and after a discard.

const CHIP := 26
const CHIP_COMPACT := 44

# Map HUD = true (chips tappable to discard); combat = false (display only). Set before the node
# enters the tree (refresh runs in _ready).
var interactive: bool = true


func _ready() -> void:
	add_theme_constant_override("separation", 5)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	size_flags_vertical = SIZE_SHRINK_CENTER
	refresh()


func refresh() -> void:
	for c in get_children():
		c.queue_free()
	if GameData.current_run == null:
		return

	var relics: Array = GameData.current_run.relics
	var capacity: int = GameData.value("relic.capacity")
	add_child(_make_count_label(relics.size(), capacity))

	for relic_id: String in relics:
		var relic := RelicData.get_relic(relic_id)
		if relic != null:
			add_child(_make_chip(relic))


# "Relics 2/5" — the at-a-glance read of how many slots are used and how many remain.
func _make_count_label(used: int, capacity: int) -> Label:
	var lbl := Label.new()
	lbl.text = "Relics %d/%d " % [used, capacity]
	lbl.add_theme_font_size_override("font_size", 22 if UIScale.is_compact() else 14)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_vertical = SIZE_SHRINK_CENTER
	lbl.modulate = Color(0.8, 0.8, 0.88)
	return lbl


func _make_chip(relic: RelicData) -> Button:
	var s: int = CHIP_COMPACT if UIScale.is_compact() else CHIP
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(s, s)
	btn.size_flags_vertical = SIZE_SHRINK_CENTER
	btn.text = relic.letter
	btn.add_theme_font_size_override("font_size", 24 if UIScale.is_compact() else 14)
	btn.add_theme_color_override("font_color", Color(0.06, 0.06, 0.08))
	btn.add_theme_color_override("font_hover_color", Color(0.06, 0.06, 0.08))
	var tip := "%s — %s" % [relic.display_name, relic.description]
	if interactive:
		tip += "\n(tap to discard)"
	btn.tooltip_text = tip
	var style := StyleBoxFlat.new()
	style.bg_color = relic.color
	style.set_corner_radius_all(7)
	style.set_border_width_all(2)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	btn.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = relic.color.lightened(0.12)
	btn.add_theme_stylebox_override("hover", hover)
	if interactive:
		btn.pressed.connect(func() -> void: _confirm_discard(relic))
	else:
		btn.mouse_default_cursor_shape = Control.CURSOR_ARROW
	return btn


func _confirm_discard(relic: RelicData) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Discard Relic"
	dlg.dialog_text = "Discard %s?\n\n%s\n\nThis cannot be undone." % [relic.display_name, relic.description]
	dlg.ok_button_text = "Discard"
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		if GameData.current_run != null:
			GameData.current_run.discard_relic(relic.id)
		refresh()
	)
	dlg.canceled.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	dlg.popup_centered()
