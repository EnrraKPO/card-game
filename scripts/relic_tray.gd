class_name RelicTray
extends BoxContainer

# A compact inline strip of the run's relics. Two orientations from one component (set `vertical`
# before the node enters the tree, like `interactive`): horizontal, living INSIDE the top bar (no
# row of its own — mobile screen space is tight), and vertical, filling combat's left-edge relic
# column now that combat shows no header at all. Layout: a "X/Y" slot count, then a small coloured
# chip per owned relic. Hovering a chip describes its effect. Used interactive in the map HUD (tap
# a chip to discard — see RunData.discard_relic) and read-only in combat. Rebuilt on entry and
# after a discard.

const CHIP := 34
const CHIP_COMPACT := 44
# Vertical-strip chips run MUCH larger: relics matter, the strip owns most of combat's left
# rail, and its chips are the only place a firing relic announces itself — small enough to miss
# defeats the point.
const CHIP_VERTICAL := 64
const CHIP_VERTICAL_COMPACT := 76

# Whether the detail overlay a chip opens offers DISCARD (see RelicInspector): map HUD = true,
# combat = false (mid-fight relics are info-only). Tapping a chip opens the overlay in both
# modes — it's the only relic-reading path on touch, where hover tooltips don't exist. Set
# before the node enters the tree (refresh runs in _ready).
var interactive: bool = true

var _chips: Dictionary = {}   # relic_id -> Button, so a firing relic can glint its chip


func _ready() -> void:
	add_theme_constant_override("separation", 5)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	if not vertical:
		size_flags_vertical = SIZE_SHRINK_CENTER   # centre in the header row; the vertical
		# strip instead fills its column top-down (chips stack from the count label)
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


# "Relics 2/5" — the at-a-glance read of how many slots are used and how many remain. The vertical
# strip is too narrow for the word, so there it's just "2/5" (the strip carries a "Relics" tooltip).
func _make_count_label(used: int, capacity: int) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 22 if UIScale.is_compact() else 18)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if vertical:
		lbl.text = "%d/%d" % [used, capacity]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", Color(0.72, 0.78, 0.92))   # on the dark
		# track panel combat frames the strip with (ScreenUI.MANA_TRACK_BG)
	else:
		lbl.text = "Relics %d/%d " % [used, capacity]
		lbl.size_flags_vertical = SIZE_SHRINK_CENTER
		lbl.add_theme_color_override("font_color", Color("6b5636"))   # sits on the header_chip's
																		# cream capsule (ScreenUI.SURFACE_DEEP)
	return lbl


func _make_chip(relic: RelicData) -> Button:
	var s: int
	if vertical:
		s = CHIP_VERTICAL_COMPACT if UIScale.is_compact() else CHIP_VERTICAL
	else:
		s = CHIP_COMPACT if UIScale.is_compact() else CHIP
	var btn: Button = TextIcons.TipButton.new()   # tooltip renders keyword icons
	btn.custom_minimum_size = Vector2(s, s)
	if vertical:
		btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	else:
		btn.size_flags_vertical = SIZE_SHRINK_CENTER
	btn.tooltip_text = "%s — %s" % [relic.display_name, relic.description]
	if relic.icon != null:
		_style_icon_chip(btn, relic.icon)
	else:
		_style_letter_chip(btn, relic)
	# Tap → the full detail overlay, everywhere. Discarding (map only) lives INSIDE the
	# overlay as an explicit button, so a stray tap can never start a discard.
	btn.pressed.connect(func() -> void:
		RelicInspector.open(self, relic, interactive, func() -> void: _discard(relic)))
	return btn


# The illustrated variant: the art fills the chip, frameless (it carries its own frame), with just
# a faint rounded hover wash so the map HUD's tap-to-discard still has feedback.
func _style_icon_chip(btn: Button, icon: Texture2D) -> void:
	btn.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(1, 1, 1, 0.14)
	hover.set_corner_radius_all(7)
	btn.add_theme_stylebox_override("hover", hover)
	var tex := TextureRect.new()
	tex.texture = icon
	tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(tex)


# The default coloured-letter chip, for relics with no art.
func _style_letter_chip(btn: Button, relic: RelicData) -> void:
	btn.text = relic.letter
	btn.add_theme_font_size_override("font_size", 24 if UIScale.is_compact() else 18)
	btn.add_theme_color_override("font_color", Color(0.06, 0.06, 0.08))
	btn.add_theme_color_override("font_hover_color", Color(0.06, 0.06, 0.08))
	var style := StyleBoxFlat.new()
	style.bg_color = relic.color
	style.set_corner_radius_all(7)
	style.set_border_width_all(2)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	btn.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = relic.color.lightened(0.12)
	btn.add_theme_stylebox_override("hover", hover)


# The overlay's Discard action (see _make_chip) — the overlay itself was the deliberate step,
# so this applies immediately; no second confirmation dialog.
func _discard(relic: RelicData) -> void:
	if GameData.current_run != null:
		GameData.current_run.discard_relic(relic.id)
	refresh()
