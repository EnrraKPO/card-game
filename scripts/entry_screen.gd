extends Control

var name_input: LineEdit
var error_label: Label


func _ready() -> void:
	Nav.clear_back()   # onboarding root — the OS back gesture stays inert (never quits)
	if not GameData.username.is_empty():
		# Deferred: changing scene mid-_ready trips the tree's "busy adding children" guard.
		get_tree().change_scene_to_file.call_deferred("res://scenes/game_slots.tscn")
		return

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var compact := UIScale.is_compact()
	var field_size := Vector2(560, 130) if compact else Vector2(480, 100)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = ScreenUI.BG_COLOR
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 28 if compact else 24)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Enter your name"
	title.add_theme_font_size_override("font_size", 64 if compact else 56)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	name_input = LineEdit.new()
	name_input.custom_minimum_size = field_size
	name_input.placeholder_text = "Username"
	name_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_input.add_theme_font_size_override("font_size", 40 if compact else 32)
	name_input.text_submitted.connect(_on_continue_pressed.unbind(1))
	vbox.add_child(name_input)

	error_label = Label.new()
	error_label.modulate = Color(1, 0.3, 0.3, 1)
	error_label.add_theme_font_size_override("font_size", 28 if compact else 22)
	error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(error_label)

	var button := Button.new()
	button.text = "Continue"
	button.custom_minimum_size = field_size
	button.add_theme_font_size_override("font_size", 40 if compact else 32)
	button.pressed.connect(_on_continue_pressed)
	vbox.add_child(button)

	name_input.grab_focus()


func _on_continue_pressed() -> void:
	var username := name_input.text.strip_edges()
	if username.is_empty():
		error_label.text = "Please enter a name."
		return
	GameData.username = username
	get_tree().change_scene_to_file("res://scenes/game_slots.tscn")
