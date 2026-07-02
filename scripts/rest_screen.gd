extends Control

# Fraction of the King's max health a rest site restores.
const HEAL_PERCENT := 0.30

var _hp_label: Label
var _rest_btn: Button


func get_chrome() -> Dictionary:
	return {"title": "Rest Site", "exit": _on_continue, "show_footer": true}


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 40)
	add_child(vbox)

	var subtitle := Label.new()
	subtitle.text = "Your King recovers %d%% of maximum health." % int(HEAL_PERCENT * 100)
	subtitle.add_theme_font_size_override("font_size", 30)
	subtitle.add_theme_color_override("font_color", Color("5a4a38"))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	_hp_label = Label.new()
	_hp_label.add_theme_font_size_override("font_size", 64)
	_hp_label.add_theme_color_override("font_color", Color("1f7a35"))
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_hp_label)

	_rest_btn = ScreenUI.action_button("", _on_rest, Vector2(460, 110), 34, ScreenUI.CHROME_CONFIRM)
	_rest_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
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
	Nav.goto("res://scenes/map.tscn")
