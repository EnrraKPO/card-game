extends Control

# Save selection — the top level after login. Each slot is an independent game (its own
# meta-progression + at most one in-progress run). Picking a slot enters its hub
# (game_world); the run itself is started/continued there.

var _confirm_delete: ConfirmationDialog
var _confirm_reset: ConfirmationDialog
var _pending_delete_slot: int = -1


func get_chrome() -> Dictionary:
	# Root picker — no header (Shell's own background already paints behind it). show_footer:
	# true still gets it the standard Shell-built footer + inset margin, just with a
	# "Reset profile" action instead of the usual Back (there's nowhere to go back to here).
	return {"show_header": false, "show_footer": true, "footer_actions": [
		{"label": "Reset profile", "action": func(): _confirm_reset.popup_centered(),
			"align": "right"},
	]}


func _ready() -> void:
	Nav.clear_back()   # save-select root — the OS back gesture stays inert (never quits)
	# Rebuild if the form factor flips (e.g. previewing mobile by resizing in the editor).
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)

	_confirm_delete = ConfirmationDialog.new()
	_confirm_delete.title = "Delete save"
	_confirm_delete.confirmed.connect(_on_delete_confirmed)
	add_child(_confirm_delete)

	_confirm_reset = ConfirmationDialog.new()
	_confirm_reset.title = "Reset profile"
	_confirm_reset.dialog_text = "This erases your name and all saves. Are you sure?"
	_confirm_reset.confirmed.connect(_on_reset_confirmed)
	add_child(_confirm_reset)

	# Big title, near-full-width tall slot rows dividing the height — proportional coverage, no
	# centered island. Shell already wraps this in the standard inset margin + footer row.
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 24)
	add_child(vbox)

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

		var idx := i
		var slot_btn := ScreenUI.action_button(_slot_label(i, started),
			func(): _on_slot_selected(idx), Vector2.ZERO, 34, ScreenUI.CHROME_NEUTRAL)
		slot_btn.size_flags_horizontal = SIZE_EXPAND_FILL
		slot_btn.size_flags_vertical = SIZE_EXPAND_FILL
		row.add_child(slot_btn)

		var del_btn := ScreenUI.action_button("Delete", func(): _on_delete_pressed(idx),
			Vector2(240, 0), 28, ScreenUI.CHROME_DANGER)
		del_btn.size_flags_vertical = SIZE_EXPAND_FILL
		del_btn.disabled = not started
		row.add_child(del_btn)
	# Reset profile is Shell's footer now (get_chrome's footer_actions) — nothing left to build here.


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
	Nav.goto("res://scenes/game_world.tscn")


func _on_delete_pressed(slot: int) -> void:
	_pending_delete_slot = slot
	_confirm_delete.dialog_text = "Delete Slot %d? This erases its progress and cannot be undone." % (slot + 1)
	_confirm_delete.popup_centered()


func _on_delete_confirmed() -> void:
	if _pending_delete_slot < 0:
		return
	GameData.delete_slot(_pending_delete_slot)
	_pending_delete_slot = -1
	Nav.goto("res://scenes/game_slots.tscn")


func _on_reset_confirmed() -> void:
	GameData.wipe_all()
	Nav.goto("res://scenes/entry_screen.tscn")
