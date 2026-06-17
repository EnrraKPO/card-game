class_name RunHUD
extends HBoxContainer

var _hp_label:   Label
var _act_label:  Label
var _gold_label: Label


func _ready() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)

	_hp_label   = _make_label(HORIZONTAL_ALIGNMENT_LEFT)
	_act_label  = _make_label(HORIZONTAL_ALIGNMENT_CENTER)
	_gold_label = _make_label(HORIZONTAL_ALIGNMENT_RIGHT)
	add_child(_hp_label)
	add_child(_act_label)
	add_child(_gold_label)
	refresh()


func refresh() -> void:
	if GameData.current_run == null:
		return
	var run := GameData.current_run
	_hp_label.text   = "  HP  %d / %d" % [run.king_health(), run.king_max_health()]
	_act_label.text  = "Act %d" % run.act
	_gold_label.text = "Gold  %d  " % run.gold


func _make_label(alignment: HorizontalAlignment) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 17)
	lbl.horizontal_alignment = alignment
	lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	return lbl
