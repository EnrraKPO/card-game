class_name CardUI
extends Control

signal pressed
signal spell_drag_started(card_ui: CardUI)
signal spell_drag_ended(card_ui: CardUI)

var card_instance: CardInstance
var _show_cost: bool

@onready var _art: TextureRect  = %Art
@onready var _name_label: Label = %NameLabel
@onready var _cost_lbl: Label   = %CostLabel
@onready var _spd_lbl: Label    = %SpdLabel
@onready var _atk_lbl: Label    = %AtkLabel
@onready var _shield_lbl: Label = %ShieldLabel
@onready var _hp_lbl: Label     = %HpLabel
@onready var _border: Panel     = %Border

static var _scene: PackedScene = null


static func create(inst: CardInstance, show_cost: bool = false) -> CardUI:
	if _scene == null:
		_scene = load("res://scenes/card_ui.tscn")
	var ui: CardUI = _scene.instantiate()
	ui.card_instance = inst
	ui._show_cost = show_cost
	return ui


func _ready() -> void:
	_apply_border_style()
	refresh()


func _apply_border_style() -> void:
	var is_king := card_instance != null and card_instance.data.is_king
	var style   := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.set_border_width_all(3 if is_king else 2)
	style.border_color = Color(1.0, 0.82, 0.2) if is_king else Color(0.45, 0.45, 0.55)
	style.set_corner_radius_all(6)
	_border.add_theme_stylebox_override("panel", style)


func refresh() -> void:
	if card_instance == null:
		return
	_art.texture = card_instance.data.image

	var is_spell := card_instance.is_spell
	_name_label.text  = card_instance.data.display_name
	_cost_lbl.text    = str(card_instance.get_attribute("cost"))
	_atk_lbl.text       = str(card_instance.get_attribute("attack"))
	_hp_lbl.text        = str(card_instance.current_health)
	_spd_lbl.text       = str(card_instance.get_attribute("speed"))
	var shld            := card_instance.current_shield
	_shield_lbl.text    = str(shld)
	_atk_lbl.visible    = not is_spell
	_shield_lbl.visible = not is_spell and shld > 0
	_hp_lbl.visible     = not is_spell
	_spd_lbl.visible    = not is_spell
	tooltip_text      = card_instance.data.description


func _make_custom_tooltip(for_text: String) -> Object:
	if for_text.is_empty():
		return null

	var panel := PanelContainer.new()
	var style  := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.14, 0.96)
	style.set_border_width_all(1)
	style.border_color = Color(0.45, 0.45, 0.6)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size.x = 220.0
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var name_lbl := Label.new()
	name_lbl.text = card_instance.data.display_name
	name_lbl.add_theme_font_size_override("font_size", 18)
	vbox.add_child(name_lbl)

	vbox.add_child(HSeparator.new())

	var desc_lbl := Label.new()
	desc_lbl.text          = for_text
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc_lbl.add_theme_font_size_override("font_size", 15)
	desc_lbl.modulate = Color(0.82, 0.82, 0.9)
	vbox.add_child(desc_lbl)

	return panel


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
	if card_instance.is_spell:
		spell_drag_started.emit(self)
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
		if card_instance != null and card_instance.is_spell:
			spell_drag_ended.emit(self)
