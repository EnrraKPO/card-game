extends Control

# The onboarding LANGUAGE GATE — the game's first screen for a fresh player. Because no
# language has been chosen yet, all the reading copy (title, field, error) is shown in BOTH
# shipped languages at once ("Enter your name / Escribe tu nombre"), and the single Continue
# button is replaced by one Start button per language: "Start" (English) and "Comenzar"
# (Español), each captioned with its language name. Pressing either locks in that language
# AND submits the name, then enters the game. Returning players (username already set) skip
# straight past to the save-slot select.

var name_input: LineEdit
var error_label: Label


func _ready() -> void:
	Sfx.music("music_splash")
	Nav.clear_back()   # onboarding root — the OS back gesture stays inert (never quits)
	if not GameData.username.is_empty():
		# Deferred: changing scene mid-_ready trips the tree's "busy adding children" guard.
		Nav.goto.call_deferred("res://scenes/game_slots.tscn")
		return

	var compact := UIScale.is_compact()
	var field_size := Vector2(560, 130) if compact else Vector2(480, 100)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 28 if compact else 24)
	center.add_child(vbox)

	var title := Label.new()
	title.text = _bilingual("entry.title")
	title.add_theme_font_size_override("font_size", 64 if compact else 56)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	name_input = LineEdit.new()
	name_input.custom_minimum_size = field_size
	name_input.placeholder_text = _bilingual("entry.username_placeholder")
	name_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_input.add_theme_font_size_override("font_size", 40 if compact else 32)
	# Enter submits in the OS-detected language (the Start buttons are the explicit pick).
	name_input.text_submitted.connect(func(_t: String) -> void: _start(Loc.locale()))
	vbox.add_child(name_input)

	error_label = Label.new()
	error_label.add_theme_color_override("font_color", Color(0.75, 0.1, 0.1, 1))
	error_label.add_theme_font_size_override("font_size", 28 if compact else 22)
	error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(error_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 32 if compact else 28)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	for lang: String in Loc.LANGS:
		buttons.add_child(_start_button(lang, compact))
	vbox.add_child(buttons)

	name_input.grab_focus()


# The joined reading of a key across every shipped language, e.g. "Enter your name / Escribe
# tu nombre" — used only here, on the pre-pick gate.
func _bilingual(key: String) -> String:
	var parts := PackedStringArray()
	for lang: String in Loc.LANGS:
		parts.append(Loc.t_in(lang, key))
	return " / ".join(parts)


# One Start button per language: its face is that language's word for Start (entry.start),
# with the language name captioned beneath. Pressing it locks in that language.
func _start_button(lang: String, compact: bool) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	var size := Vector2(320, 130) if compact else Vector2(280, 100)
	var btn := ScreenUI.action_button(Loc.t_in(lang, "entry.start"), func() -> void: _start(lang),
		size, 40 if compact else 32, ScreenUI.CHROME_CONFIRM)
	col.add_child(btn)

	var caption := Label.new()
	caption.text = "(" + Loc.language_name(lang) + ")"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 26 if compact else 22)
	caption.add_theme_color_override("font_color", Color(0.7, 0.72, 0.8, 1))
	col.add_child(caption)
	return col


# Commit: validate the name, lock in the chosen language, and enter the game.
func _start(lang: String) -> void:
	var username := name_input.text.strip_edges()
	if username.is_empty():
		error_label.text = _bilingual("entry.error_empty")
		Vfx.play("ui_error_flash", error_label)   # carries the error sound
		return
	Loc.set_locale(lang)
	GameData.username = username
	Nav.goto("res://scenes/game_slots.tscn")
