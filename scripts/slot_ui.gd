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
	# Deliberately NOT ScreenUI.SURFACE_DEEP — that's an app-chrome tone (now light, to match the
	# app's plastic-toy palette), but an empty battlefield slot is the game board, not UI chrome; it
	# needs to stay a dark, receding "empty" surface so cards read clearly against it either way.
	# Still themeable via ScreenUI.SLOT_* (backed by UIPalette's own "Combat board" group).
	var style := StyleBoxFlat.new()
	style.bg_color = ScreenUI.SLOT_EMPTY
	if _targetable:
		style.set_border_width_all(3)
		style.border_color = ScreenUI.SLOT_BORDER_HIGHLIGHT
	else:
		style.set_border_width_all(1)
		style.border_color = ScreenUI.SLOT_BORDER_IDLE
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
		var old_slot := old_parent as SlotUI
		old_slot._card_ui = null
		if card.pressed.is_connected(old_slot._on_card_pressed):
			card.pressed.disconnect(old_slot._on_card_pressed)
		old_slot.remove_child(card)
	elif old_parent != null:
		old_parent.remove_child(card)
	add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# CardUI._gui_input calls accept_event() on every click release (long-press/tooltip handling),
	# which marks the event handled and stops it from ever bubbling to this slot's own _gui_input —
	# MOUSE_FILTER_PASS doesn't help, since Godot only forwards an event to the parent if the child
	# left it unhandled. So we listen to the card's `pressed` signal directly instead of relying on
	# GUI event propagation (see Combat._on_board_slot_pressed, the click-to-open-ability-tray path).
	if not card.pressed.is_connected(_on_card_pressed):
		card.pressed.connect(_on_card_pressed)
	# Face the opponent: the card is authored in the PLAYER's orientation, so player cards (and the
	# hand, which never flips) read identically with no change. Enemy cards (right half, facing
	# left) mirror that layout so the two armies read as mirror images across the board. See
	# CardUI.set_flipped.
	card.set_flipped(owner_id == 1)


func _on_card_pressed() -> void:
	pressed.emit()


func clear_card() -> CardUI:
	var card := _card_ui
	if _card_ui != null and _card_ui.get_parent() == self:
		remove_child(_card_ui)
	if card != null and card.pressed.is_connected(_on_card_pressed):
		card.pressed.disconnect(_on_card_pressed)
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
		# Spells drop only on ELIGIBLE slots: during a spell drag the board marks targetable
		# exactly the valid picks (occupied units passing the spell's conditions — and for
		# MANUAL_SLOT spells, eligible EMPTY own slots too), so an invalid drop is rejected at
		# hover time. See SpellCaster._on_spell_drag_started.
		return _targetable
	if _card_ui != null:
		return false
	if accept_check.is_valid():
		return accept_check.call(card_ui, self)
	return true


func _drop_data(_at: Vector2, data: Variant) -> void:
	card_dropped.emit(data as CardUI)
