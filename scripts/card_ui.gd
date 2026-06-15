class_name CardUI
extends PanelContainer

signal pressed

var card_instance: CardInstance
var _show_cost: bool

var _name_label: Label
var _atk_val: Label
var _hp_val: Label
var _spd_val: Label
var _cost_row: Control
var _cost_val: Label


static func create(inst: CardInstance, show_cost: bool = false) -> CardUI:
	var ui := CardUI.new()
	ui.card_instance = inst
	ui._show_cost = show_cost
	return ui


func _ready() -> void:
	custom_minimum_size = Vector2(90, 118)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_style()
	_build_layout()
	refresh()


func _apply_style() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.13, 0.18)
	var is_king := card_instance != null and card_instance.data.is_king
	style.set_border_width_all(3 if is_king else 2)
	style.border_color = Color(1.0, 0.82, 0.2) if is_king else Color(0.45, 0.45, 0.55)
	style.set_corner_radius_all(5)
	add_theme_stylebox_override("panel", style)


func _build_layout() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	margin.add_child(vbox)

	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 13)
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_name_label)

	vbox.add_child(HSeparator.new())

	var stats := GridContainer.new()
	stats.columns = 2
	stats.add_theme_constant_override("h_separation", 4)
	stats.add_theme_constant_override("v_separation", 2)
	vbox.add_child(stats)

	_make_key(stats, "ATK")
	_atk_val = _make_val(stats)

	_make_key(stats, "HP")
	_hp_val = _make_val(stats)

	_make_key(stats, "SPD")
	_spd_val = _make_val(stats)

	_cost_row = HBoxContainer.new()
	_cost_row.add_theme_constant_override("separation", 4)
	_cost_row.visible = _show_cost
	vbox.add_child(_cost_row)
	_make_key(_cost_row, "Cost")
	_cost_val = _make_val(_cost_row)


func _make_key(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.modulate = Color(0.7, 0.7, 0.75)
	parent.add_child(lbl)


func _make_val(parent: Control) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)
	return lbl


func refresh() -> void:
	if card_instance == null:
		return
	_name_label.text = card_instance.data.display_name
	_atk_val.text = str(card_instance.data.attack)
	_hp_val.text = "%d / %d" % [card_instance.current_health, card_instance.data.health]
	_spd_val.text = str(card_instance.data.speed)
	_cost_row.visible = _show_cost
	if _show_cost:
		_cost_val.text = str(card_instance.data.cost)


func set_selected(selected: bool) -> void:
	modulate = Color(0.65, 1.0, 1.5) if selected else Color.WHITE


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			pressed.emit()
			accept_event()


func _get_drag_data(at_position: Vector2) -> Variant:
	if card_instance == null:
		return null
	modulate.a = 0.0
	var preview := CardUI.create(card_instance, _show_cost)
	preview.custom_minimum_size = custom_minimum_size
	preview.modulate.a = 0.7
	var wrapper := Control.new()
	wrapper.add_child(preview)
	preview.position = -at_position
	set_drag_preview(wrapper)
	return self


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		modulate.a = 1.0
