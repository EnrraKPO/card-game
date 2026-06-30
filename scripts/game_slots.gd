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

	# This screen is the root picker (no ScreenUI chrome), so it lays its own dark background and
	# fills the whole screen: big title, near-full-width tall slot rows dividing the height, and a
	# real Reset button — proportional coverage, no centered island.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = ScreenUI.BG_COLOR
	add_child(bg)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var m := int(UIScale.safe_inset() + 36.0)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, m)
	add_child(pad)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = SIZE_EXPAND_FILL
	vbox.size_flags_vertical = SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 24)
	pad.add_child(vbox)

	var title := Label.new()
	title.text = "Select Save"
	title.add_theme_font_size_override("font_size", 64)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	for i in GameData.SLOT_COUNT:
		var started := GameData.slot_started(i)

		var row := HBoxContainer.new()
		row.size_flags_horizontal = SIZE_EXPAND_FILL
		row.size_flags_vertical = SIZE_EXPAND_FILL   # the slot rows divide the height — big and tall
		row.add_theme_constant_override("separation", 20)
		vbox.add_child(row)

		var slot_btn := Button.new()
		slot_btn.text = _slot_label(i, started)
		slot_btn.add_theme_font_size_override("font_size", 34)
		slot_btn.size_flags_horizontal = SIZE_EXPAND_FILL
		slot_btn.size_flags_vertical = SIZE_EXPAND_FILL
		var idx := i
		slot_btn.pressed.connect(func(): _on_slot_selected(idx))
		row.add_child(slot_btn)

		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.add_theme_font_size_override("font_size", 28)
		del_btn.custom_minimum_size.x = 240.0
		del_btn.size_flags_vertical = SIZE_EXPAND_FILL
		del_btn.disabled = not started
		del_btn.pressed.connect(func(): _on_delete_pressed(idx))
		row.add_child(del_btn)

	# Global reset (name + every save) — a real button at the bottom-right.
	var footer := HBoxContainer.new()
	footer.size_flags_horizontal = SIZE_EXPAND_FILL
	vbox.add_child(footer)
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var reset_btn := Button.new()
	reset_btn.text = "Reset profile"
	reset_btn.add_theme_font_size_override("font_size", 24)
	reset_btn.custom_minimum_size = Vector2(300, 90)
	reset_btn.pressed.connect(func(): _confirm_reset.popup_centered())
	footer.add_child(reset_btn)

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
