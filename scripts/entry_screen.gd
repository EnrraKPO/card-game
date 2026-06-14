extends Control

var name_input: LineEdit
var error_label: Label


func _ready() -> void:
	if not GameData.username.is_empty():
		get_tree().change_scene_to_file("res://scenes/hello_screen.tscn")
		return

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Enter your name"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	name_input = LineEdit.new()
	name_input.custom_minimum_size = Vector2(320, 48)
	name_input.placeholder_text = "Username"
	name_input.add_theme_font_size_override("font_size", 20)
	name_input.text_submitted.connect(_on_continue_pressed.unbind(1))
	vbox.add_child(name_input)

	error_label = Label.new()
	error_label.modulate = Color(1, 0.3, 0.3, 1)
	error_label.add_theme_font_size_override("font_size", 16)
	error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(error_label)

	var button := Button.new()
	button.text = "Continue"
	button.custom_minimum_size = Vector2(320, 48)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(_on_continue_pressed)
	vbox.add_child(button)

	name_input.grab_focus()


func _on_continue_pressed() -> void:
	var username := name_input.text.strip_edges()
	if username.is_empty():
		error_label.text = "Please enter a name."
		return
	GameData.username = username
	get_tree().change_scene_to_file("res://scenes/hello_screen.tscn")
