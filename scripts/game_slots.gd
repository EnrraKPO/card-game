extends Control

var _confirm_dialog: ConfirmationDialog
var _pending_delete_slot: int = -1


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Select Save Slot"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	for i in GameData.SLOT_COUNT:
		var slot_data := GameData.get_slot_data(i)
		var is_empty := slot_data.is_empty()

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		vbox.add_child(row)

		var slot_btn := Button.new()
		slot_btn.custom_minimum_size = Vector2(320, 64)
		slot_btn.add_theme_font_size_override("font_size", 18)
		slot_btn.text = "Slot %d  —  %s" % [i + 1, "Empty" if is_empty else "Continue"]
		slot_btn.size_flags_horizontal = SIZE_EXPAND_FILL
		var idx := i
		slot_btn.pressed.connect(func(): _on_slot_selected(idx))
		row.add_child(slot_btn)

		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.custom_minimum_size = Vector2(80, 64)
		del_btn.add_theme_font_size_override("font_size", 14)
		del_btn.disabled = is_empty
		del_btn.pressed.connect(func(): _on_delete_pressed(idx))
		row.add_child(del_btn)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.anchor_left = 0.0
	back_btn.anchor_top = 1.0
	back_btn.anchor_right = 0.0
	back_btn.anchor_bottom = 1.0
	back_btn.offset_left = 16
	back_btn.offset_top = -48
	back_btn.offset_right = 110
	back_btn.offset_bottom = -16
	back_btn.pressed.connect(_on_back_pressed)
	add_child(back_btn)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "Delete save"
	_confirm_dialog.confirmed.connect(_on_delete_confirmed)
	add_child(_confirm_dialog)


func _on_slot_selected(slot: int) -> void:
	if GameData.get_slot_data(slot).is_empty():
		GameData.new_run(slot)
	else:
		GameData.load_run(slot)
	get_tree().change_scene_to_file("res://scenes/map.tscn")


func _on_delete_pressed(slot: int) -> void:
	_pending_delete_slot = slot
	_confirm_dialog.dialog_text = "Delete Slot %d? This cannot be undone." % (slot + 1)
	_confirm_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	if _pending_delete_slot < 0:
		return
	GameData.delete_slot(_pending_delete_slot)
	_pending_delete_slot = -1
	get_tree().change_scene_to_file("res://scenes/game_slots.tscn")


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/hello_screen.tscn")
