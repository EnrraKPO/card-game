extends Control

# Fraction of the King's max health a rest site restores.
const HEAL_PERCENT := 0.30

var _hp_label: Label
var _rest_btn: Button


func _ready() -> void:
	var vbox := ScreenUI.frame_centered(self, "Rest Site", _on_continue)
	vbox.add_theme_constant_override("separation", 40)

	var subtitle := Label.new()
	subtitle.text = "Your King recovers %d%% of maximum health." % int(HEAL_PERCENT * 100)
	subtitle.add_theme_font_size_override("font_size", 30)
	subtitle.modulate = Color(0.8, 0.8, 0.85)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	_hp_label = Label.new()
	_hp_label.add_theme_font_size_override("font_size", 64)
	_hp_label.modulate = Color(0.4, 0.9, 0.45)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_hp_label)

	_rest_btn = Button.new()
	_rest_btn.add_theme_font_size_override("font_size", 34)
	_rest_btn.custom_minimum_size = Vector2(460, 110)
	_rest_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	_rest_btn.pressed.connect(_on_rest)
	vbox.add_child(_rest_btn)

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
