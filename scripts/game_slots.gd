extends Control

# Save selection — the top level after login. Each slot is an independent game (its own
# meta-progression + at most one in-progress run). Picking a slot enters its hub
# (game_world); the run itself is started/continued there.

var _confirm_delete: ConfirmationDialog
var _confirm_reset: ConfirmationDialog
var _pending_delete_slot: int = -1


func _ready() -> void:
	Nav.clear_back()   # save-select root — the OS back gesture stays inert (never quits)
	# Rebuild if the form factor flips (e.g. previewing mobile by resizing in the editor).
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)
	var compact := UIScale.is_compact()

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20 if compact else 22)
	if compact:
		# Fill the screen so the slot rows are wide, tall and easy to tap.
		var pad := MarginContainer.new()
		pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		for side in ["left", "right", "top", "bottom"]:
			pad.add_theme_constant_override("margin_" + side, 64)
		add_child(pad)
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		pad.add_child(vbox)
	else:
		# A wide, centered menu column (balanced margins, big readable rows) — not a thin strip.
		vbox.custom_minimum_size.x = 860.0
		var center := CenterContainer.new()
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(center)
		center.add_child(vbox)

	var title := Label.new()
	title.text = "Select Save"
	title.add_theme_font_size_override("font_size", 48 if compact else 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	for i in GameData.SLOT_COUNT:
		var started := GameData.slot_started(i)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		vbox.add_child(row)

		var slot_btn := Button.new()
		slot_btn.custom_minimum_size = Vector2(380, 96 if compact else 80)
		slot_btn.add_theme_font_size_override("font_size", 24 if compact else 26)
		slot_btn.text = _slot_label(i, started)
		slot_btn.size_flags_horizontal = SIZE_EXPAND_FILL
		var idx := i
		slot_btn.pressed.connect(func(): _on_slot_selected(idx))
		row.add_child(slot_btn)

		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.custom_minimum_size = Vector2(120, 96 if compact else 80)
		del_btn.add_theme_font_size_override("font_size", 18)
		del_btn.disabled = not started
		del_btn.pressed.connect(func(): _on_delete_pressed(idx))
		row.add_child(del_btn)

	# Global reset (name + every save), bottom-right.
	var reset_btn := Button.new()
	reset_btn.text = "Reset profile"
	reset_btn.add_theme_font_size_override("font_size", 18 if compact else 13)
	reset_btn.set_anchors_and_offsets_preset(PRESET_BOTTOM_RIGHT)
	reset_btn.offset_left = -(220 if compact else 150)
	reset_btn.offset_top = -(64 if compact else 48)
	reset_btn.offset_right = -16
	reset_btn.offset_bottom = -16
	reset_btn.pressed.connect(func(): _confirm_reset.popup_centered())
	add_child(reset_btn)

	_confirm_delete = ConfirmationDialog.new()
	_confirm_delete.title = "Delete save"
	_confirm_delete.confirmed.connect(_on_delete_confirmed)
	add_child(_confirm_delete)

	_confirm_reset = ConfirmationDialog.new()
	_confirm_reset.title = "Reset profile"
	_confirm_reset.dialog_text = "This erases your name and all saves. Are you sure?"
	_confirm_reset.confirmed.connect(_on_reset_confirmed)
	add_child(_confirm_reset)


func _slot_label(slot: int, started: bool) -> String:
	if not started:
		return "Slot %d  —  New Game" % (slot + 1)
	var profile := GameData.peek_profile(slot)
	var king := CardData.get_card(profile.get_selected_king())
	var king_name: String = king.display_name if king != null else profile.get_selected_king()
	var run_state := "Run in progress" if GameData.slot_has_run(slot) else "No active run"
	return "Slot %d  —  %s · %s" % [slot + 1, king_name, run_state]


func _on_slot_selected(slot: int) -> void:
	GameData.select_slot(slot)
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")


func _on_delete_pressed(slot: int) -> void:
	_pending_delete_slot = slot
	_confirm_delete.dialog_text = "Delete Slot %d? This erases its progress and cannot be undone." % (slot + 1)
	_confirm_delete.popup_centered()


func _on_delete_confirmed() -> void:
	if _pending_delete_slot < 0:
		return
	GameData.delete_slot(_pending_delete_slot)
	_pending_delete_slot = -1
	get_tree().change_scene_to_file("res://scenes/game_slots.tscn")


func _on_reset_confirmed() -> void:
	GameData.wipe_all()
	get_tree().change_scene_to_file("res://scenes/entry_screen.tscn")
