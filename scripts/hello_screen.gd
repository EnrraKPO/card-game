extends Control

var confirm_dialog: ConfirmationDialog


func _ready() -> void:
	Nav.clear_back()   # onboarding screen — the OS back gesture stays inert (never quits)
	var compact := UIScale.is_compact()

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 40 if compact else 32)
	center.add_child(vbox)

	var hello_label := Label.new()
	hello_label.text = "Hello %s!" % GameData.username
	hello_label.add_theme_font_size_override("font_size", 72 if compact else 80)
	hello_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hello_label)

	var play_btn := ScreenUI.action_button("Play", _on_play_pressed,
		Vector2(560, 140) if compact else Vector2(440, 112), 44 if compact else 36,
		ScreenUI.CHROME_CONFIRM)
	vbox.add_child(play_btn)

	var reset_btn := ScreenUI.action_button("Reset profile", _on_reset_pressed, Vector2.ZERO,
		24 if compact else 18, ScreenUI.CHROME_DANGER)
	reset_btn.anchor_left = 1.0
	reset_btn.anchor_top = 1.0
	reset_btn.anchor_right = 1.0
	reset_btn.anchor_bottom = 1.0
	var rw := 280.0 if compact else 220.0
	var rh := 96.0 if compact else 72.0
	var rm := UIScale.safe_inset() + 36.0
	reset_btn.offset_left = -(rw + rm)
	reset_btn.offset_top = -(rh + rm)
	reset_btn.offset_right = -rm
	reset_btn.offset_bottom = -rm
	add_child(reset_btn)

	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.title = "Reset profile"
	confirm_dialog.dialog_text = "This will erase your name and all save slots. Are you sure?"
	confirm_dialog.confirmed.connect(_on_reset_confirmed)
	add_child(confirm_dialog)


func _on_play_pressed() -> void:
	Nav.goto("res://scenes/game_slots.tscn")


func _on_reset_pressed() -> void:
	confirm_dialog.popup_centered()


func _on_reset_confirmed() -> void:
	for i in GameData.SLOT_COUNT:
		GameData.delete_slot(i)
	GameData.username = ""
	Nav.goto("res://scenes/entry_screen.tscn")
