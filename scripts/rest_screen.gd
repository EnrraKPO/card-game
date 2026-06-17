extends Control

# Fraction of the King's max health a rest site restores.
const HEAL_PERCENT := 0.30

var _hp_label: Label
var _rest_btn: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.06, 0.1)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 32)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Rest Site"
	title.add_theme_font_size_override("font_size", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Your King recovers %d%% of maximum health." % int(HEAL_PERCENT * 100)
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.modulate = Color(0.8, 0.8, 0.85)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	_hp_label = Label.new()
	_hp_label.add_theme_font_size_override("font_size", 24)
	_hp_label.modulate = Color(0.4, 0.9, 0.45)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_hp_label)

	_rest_btn = Button.new()
	_rest_btn.add_theme_font_size_override("font_size", 20)
	_rest_btn.custom_minimum_size = Vector2(220, 0)
	_rest_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	_rest_btn.pressed.connect(_on_rest)
	vbox.add_child(_rest_btn)

	var continue_btn := Button.new()
	continue_btn.text = "Continue"
	continue_btn.add_theme_font_size_override("font_size", 18)
	continue_btn.custom_minimum_size = Vector2(180, 0)
	continue_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	continue_btn.pressed.connect(_on_continue)
	vbox.add_child(continue_btn)

	_refresh()


func _refresh() -> void:
	var run := GameData.current_run
	if run == null:
		_hp_label.text = ""
		_rest_btn.disabled = true
		return
	_hp_label.text = "HP  %d / %d" % [run.king_health(), run.king_max_health()]
	var full: bool = run.king_damage <= 0
	_rest_btn.disabled = full
	if full:
		_rest_btn.text = "Already at full health"
	else:
		_rest_btn.text = "Rest  (+%d HP)" % _heal_amount(run)


func _heal_amount(run: RunData) -> int:
	var heal: int = int(ceil(run.king_max_health() * HEAL_PERCENT))
	return mini(heal, run.king_damage)


func _on_rest() -> void:
	var run := GameData.current_run
	if run == null:
		return
	run.king_damage = maxi(0, run.king_damage - _heal_amount(run))
	GameData.save_run()
	_refresh()


func _on_continue() -> void:
	get_tree().change_scene_to_file("res://scenes/map.tscn")
