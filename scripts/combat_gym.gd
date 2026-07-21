extends Control

# Combat Gym (debug, reached from the map's bottom bar): every encounter template in the
# game, launchable INSTANTLY at any difficulty. The dial picks a run depth (global floor);
# the launched fight gets exactly the power a real fight at that depth would (convex ramp +
# the template's own power_bonus — see EncounterTemplateData). Fights are flagged practice:
# they play with the CURRENT run's deck and king health but their ending writes nothing
# (no rewards, no king carry, no map advance, no save, no run end) and returns here.

var _slider: HSlider
var _power_lbl: Label


func _ready() -> void:
	_build()


func get_chrome() -> Dictionary:
	return {"title": "Combat Gym", "exit": _leave, "show_footer": true}


func _max_depth() -> int:
	return MapData.STAGES * MapData.FLOORS - 1


func _power() -> float:
	return EncounterTemplateData.power_for_depth(int(_slider.value))


func _build() -> void:
	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	body.add_theme_constant_override("separation", 12)
	add_child(body)

	# ── The difficulty dial: a run-depth slider, labeled with the power it produces ──
	var dial := HBoxContainer.new()
	dial.add_theme_constant_override("separation", 16)
	body.add_child(dial)

	var dial_lbl := Label.new()
	dial_lbl.text = "  Difficulty"
	dial_lbl.add_theme_font_size_override("font_size", 20)
	dial.add_child(dial_lbl)

	_slider = HSlider.new()
	_slider.min_value = 0
	_slider.max_value = _max_depth()
	_slider.step = 1
	_slider.size_flags_horizontal = SIZE_EXPAND_FILL
	_slider.size_flags_vertical = SIZE_SHRINK_CENTER
	_slider.custom_minimum_size = Vector2(0, 40)
	_slider.value = _default_depth()
	_slider.value_changed.connect(func(_v: float) -> void: _refresh_power_label())
	dial.add_child(_slider)

	_power_lbl = Label.new()
	_power_lbl.add_theme_font_size_override("font_size", 20)
	_power_lbl.custom_minimum_size = Vector2(280, 0)
	dial.add_child(_power_lbl)
	_refresh_power_label()

	var note := Label.new()
	note.text = "  Practice fights use your current deck and king health — and leave no trace: no rewards, no wounds carried, no map changes."
	note.add_theme_font_size_override("font_size", 14)
	note.modulate = Color(1, 1, 1, 0.65)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)

	# ── The template roster, grouped by node type ──
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 24)
	scroll.add_child(col)

	col.add_child(_section("Combat", MapNodeData.Type.COMBAT))
	col.add_child(_section("Elite", MapNodeData.Type.ELITE))
	col.add_child(_section("Boss", MapNodeData.Type.BOSS))


# Default the dial to the run's current stage (its opening floor), so "test what I'd meet
# around here" is the zero-effort case. No run (shouldn't happen — the gym is map-reached)
# lands mid-ramp.
func _default_depth() -> int:
	var run := GameData.current_run
	if run == null:
		return _max_depth() / 2
	return clampi((run.act - 1) * MapData.FLOORS, 0, _max_depth())


func _refresh_power_label() -> void:
	_power_lbl.text = "floor %d  →  power %.1f" % [int(_slider.value), _power()]


func _section(title: String, node_type: MapNodeData.Type) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	var templates: Array = EncounterTemplateData.all().filter(
			func(t: EncounterTemplateData) -> bool: return t.node_type == node_type)
	templates.sort_custom(func(a: EncounterTemplateData, b: EncounterTemplateData) -> bool:
		return a.id < b.id)

	var lbl := Label.new()
	lbl.text = "  %s  (%d)" % [title, templates.size()]
	lbl.add_theme_font_size_override("font_size", 22)
	box.add_child(lbl)

	# Two card-columns fill the width instead of leaving a dead span between a left-packed
	# label and a right-edge button — and halve the scroll while they're at it.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 10)
	box.add_child(grid)
	for t: EncounterTemplateData in templates:
		grid.add_child(_row(t))
	return box


func _row(t: EncounterTemplateData) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.07)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var text_col := VBoxContainer.new()
	text_col.size_flags_horizontal = SIZE_EXPAND_FILL
	text_col.add_theme_constant_override("separation", 2)
	row.add_child(text_col)

	var name_lbl := Label.new()
	name_lbl.text = t.id.capitalize()
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.clip_text = true
	text_col.add_child(name_lbl)

	var king := CardData.get_card(t.enemy_king)
	var king_name := king.display_name if king != null else t.enemy_king
	var info := Label.new()
	info.text = "vs %s   ·   stage %s, floors %s%s" % [
		king_name,
		_band(t.min_stage, t.max_stage, MapData.STAGES),
		_band(t.min_floor, t.max_floor, MapData.FLOORS - 1),
		"   ·   +%.1f power" % t.power_bonus if t.power_bonus > 0.0 else "",
	]
	info.add_theme_font_size_override("font_size", 14)
	info.modulate = Color(1, 1, 1, 0.7)
	info.clip_text = true
	text_col.add_child(info)

	var can_fight := GameData.current_run != null
	var btn := ScreenUI.action_button("Fight", func() -> void: _launch(t),
			Vector2(140, 56), 18, ScreenUI.CHROME_DEBUG)
	btn.size_flags_vertical = SIZE_SHRINK_CENTER
	btn.disabled = not can_fight
	row.add_child(btn)
	return panel


# "1–999" bands read as "any"; a pinned band reads as the numbers.
func _band(lo: int, hi: int, real_max: int) -> String:
	if hi >= 999 and lo <= 0:
		return "any"
	if hi >= 999:
		return "%d+" % lo
	if lo == hi:
		return str(lo)
	if hi >= real_max and lo <= 1:
		return "any"
	return "%d–%d" % [lo, hi]


func _launch(t: EncounterTemplateData) -> void:
	if GameData.current_run == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var enc := t.instantiate(rng, _power())
	enc.practice = true
	GameData.current_encounter = enc
	Nav.goto("res://scenes/combat.tscn")


func _leave() -> void:
	Nav.goto("res://scenes/map.tscn")
