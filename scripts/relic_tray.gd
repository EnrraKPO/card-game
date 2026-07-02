class_name RelicTray
extends HBoxContainer

# A compact inline strip of the run's relics, designed to live INSIDE the top bar (no row of its
# own — mobile screen space is tight). Layout: a "X/Y" slot count, then a small coloured chip per
# owned relic. Hovering a chip describes its effect. Used interactive in the map HUD (tap a chip to
# discard — see RunData.discard_relic) and read-only in combat. Rebuilt on entry and after a discard.

const CHIP := 34
const CHIP_COMPACT := 44

# Map HUD = true (chips tappable to discard); combat = false (display only). Set before the node
# enters the tree (refresh runs in _ready).
var interactive: bool = true

var _chips: Dictionary = {}   # relic_id -> Button, so a firing relic can glint its chip


func _ready() -> void:
	add_theme_constant_override("separation", 5)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	size_flags_vertical = SIZE_SHRINK_CENTER
	refresh()


func refresh() -> void:
	for c in get_children():
		c.queue_free()
	_chips.clear()
	if GameData.current_run == null:
		return

	var relics: Array = GameData.current_run.relics
	var capacity: int = GameData.value("relic.capacity")
	add_child(_make_count_label(relics.size(), capacity))

	for relic_id: String in relics:
		var relic := RelicData.get_relic(relic_id)
		if relic != null:
			var chip := _make_chip(relic)
			_chips[relic_id] = chip
			add_child(chip)


# A quick scale pop + brightness flash on a relic's chip — the "this relic fired" cue, played by
# combat just before the relic's effects' VFX land. No-op if the relic isn't shown or isn't laid out.
func glint(relic_id: String) -> void:
	var chip: Button = _chips.get(relic_id)
	if chip == null or chip.size == Vector2.ZERO:
		return
	chip.pivot_offset = chip.size * 0.5
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(chip, "scale", Vector2(1.45, 1.45), 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(chip, "modulate", Color(1.7, 1.7, 1.7), 0.12)
	tw.chain().tween_property(chip, "scale", Vector2.ONE, 0.22).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(chip, "modulate", Color.WHITE, 0.22)


# "Relics 2/5" — the at-a-glance read of how many slots are used and how many remain.
func _make_count_label(used: int, capacity: int) -> Label:
	var lbl := Label.new()
	lbl.text = "Relics %d/%d " % [used, capacity]
	lbl.add_theme_font_size_override("font_size", 22 if UIScale.is_compact() else 18)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_vertical = SIZE_SHRINK_CENTER
	lbl.add_theme_color_override("font_color", Color("6b5636"))   # sits on the header_chip's cream
																	# capsule (ScreenUI.SURFACE_DEEP)
	return lbl


func _make_chip(relic: RelicData) -> Button:
	var s: int = CHIP_COMPACT if UIScale.is_compact() else CHIP
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(s, s)
	btn.size_flags_vertical = SIZE_SHRINK_CENTER
	btn.text = relic.letter
	btn.add_theme_font_size_override("font_size", 24 if UIScale.is_compact() else 18)
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
