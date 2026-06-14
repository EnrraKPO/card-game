extends Control

var confirm_dialog: ConfirmationDialog


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 24)
	center.add_child(vbox)

	var hello_label := Label.new()
	hello_label.text = "Hello %s!" % GameData.username
	hello_label.add_theme_font_size_override("font_size", 48)
	hello_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hello_label)

	var play_btn := Button.new()
	play_btn.text = "Play"
	play_btn.custom_minimum_size = Vector2(200, 56)
	play_btn.add_theme_font_size_override("font_size", 24)
	play_btn.pressed.connect(_on_play_pressed)
	vbox.add_child(play_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset profile"
	reset_btn.add_theme_font_size_override("font_size", 13)
	reset_btn.anchor_left = 1.0
	reset_btn.anchor_top = 1.0
	reset_btn.anchor_right = 1.0
	reset_btn.anchor_bottom = 1.0
	reset_btn.offset_left = -150
	reset_btn.offset_top = -48
	reset_btn.offset_right = -16
	reset_btn.offset_bottom = -16
	reset_btn.pressed.connect(_on_reset_pressed)
	add_child(reset_btn)

	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.title = "Reset profile"
	confirm_dialog.dialog_text = "This will erase your saved name and return you to the start. Are you sure?"
	confirm_dialog.confirmed.connect(_on_reset_confirmed)
	add_child(confirm_dialog)


func _on_play_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/game_slots.tscn")


func _on_reset_pressed() -> void:
	confirm_dialog.popup_centered()


func _on_reset_confirmed() -> void:
	GameData.username = ""
	get_tree().change_scene_to_file("res://scenes/entry_screen.tscn")
