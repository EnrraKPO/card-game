class_name SlotUI
extends Panel

signal card_dropped(card_ui: CardUI)
signal pressed

var row: int = -1
var col: int = -1
var owner_id: int = -1
var accept_check: Callable

var _card_ui: CardUI = null
var _targetable: bool = false


func _ready() -> void:
	custom_minimum_size = Vector2(165, 216)
	_apply_style()


func set_targetable(enabled: bool) -> void:
	_targetable = enabled
	_apply_style()


func _apply_style() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.12)
	if _targetable:
		style.set_border_width_all(3)
		style.border_color = Color(0.95, 0.75, 0.1)
	else:
		style.set_border_width_all(1)
		style.border_color = Color(0.28, 0.28, 0.38)
	style.set_corner_radius_all(5)
	add_theme_stylebox_override("panel", style)


func get_card() -> CardUI:
	return _card_ui


func set_card(card: CardUI) -> void:
	if _card_ui != null and _card_ui.get_parent() == self:
		remove_child(_card_ui)
	_card_ui = card
	if card == null:
		return
	# Clear old parent slot's reference before re-parenting
	var old_parent := card.get_parent()
	if old_parent is SlotUI:
		(old_parent as SlotUI)._card_ui = null
		old_parent.remove_child(card)
	elif old_parent != null:
		old_parent.remove_child(card)
	add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func clear_card() -> CardUI:
	var card := _card_ui
	if _card_ui != null and _card_ui.get_parent() == self:
		remove_child(_card_ui)
	_card_ui = null
	return card


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			pressed.emit()
			accept_event()


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if not (data is CardUI):
		return false
	var card_ui := data as CardUI
	if card_ui.card_instance.is_spell:
		return _card_ui != null  # spells target occupied slots
	if _card_ui != null:
		return false
	if accept_check.is_valid():
		return accept_check.call(card_ui, self)
	return true


func _drop_data(_at: Vector2, data: Variant) -> void:
	card_dropped.emit(data as CardUI)
