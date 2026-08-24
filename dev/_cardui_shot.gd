extends Node
# Renders CardUI's states side by side for eyeballing — the R6 data setups: face kinds,
# composition, status views, aura, ground tint, phantom. Injection only; no game world.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_cardui_shot.tscn
const OUT := "res://dev/_cardui_out.png"
const CARD := Vector2(165, 216)


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1480, 330)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.11)
	bg.size = sv.size
	sv.add_child(bg)

	var row := HBoxContainer.new()
	row.position = Vector2(24, 20)
	row.add_theme_constant_override("separation", 20)
	sv.add_child(row)

	_shot(row, "plain face", func(_ui: CardUI) -> void: pass)
	_shot(row, "spell", func(ui: CardUI) -> void:
		ui.card_data.card_type = CardData.CardType.SPELL
		ui.card_data.display_name = "Fireball"
		ui.refresh())
	_shot(row, "king", func(ui: CardUI) -> void:
		ui.card_data.is_king = true
		ui.card_data.display_name = "King"
		ui.refresh())
	_shot(row, "composition", func(ui: CardUI) -> void:
		ui.card_data.elements.assign(["fire", "water"])
		ui.refresh())
	_shot(row, "statuses", func(ui: CardUI) -> void:
		ui.set_status_views([_pip("poison", Color(0.45, 0.75, 0.2), 3),
				_pip("gloom", Color(0.5, 0.4, 0.7), 1)]))
	_shot(row, "aura", func(ui: CardUI) -> void:
		var v := _pip("barrier", Color(0.35, 0.65, 0.95), 1)
		v.aura = true
		ui.set_status_views([v]))
	_shot(row, "ground tint", func(ui: CardUI) -> void:
		ui.set_ground_tint(Color(1.0, 0.62, 0.42)))
	_shot(row, "phantom", func(ui: CardUI) -> void:
		ui.set_phantom(true))

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED card ui states")
	get_tree().quit()


func _shot(row: Control, label_text: String, dress: Callable) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	row.add_child(box)
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color.WHITE)
	box.add_child(label)
	var data := CardData.new()
	data.display_name = "Squire"
	data.cost = 2
	data.attack = 3
	data.health = 5
	data.speed = 2
	data.shield = 1
	var ui := CardUI.create(data)
	box.add_child(ui)
	ui.custom_minimum_size = CARD
	dress.call(ui)


func _pip(id: String, color: Color, count: int) -> StatusPipView:
	var v := StatusPipView.new()
	v.id = id
	v.display_name = id.capitalize()
	v.color = color
	v.count = count
	v.stacks = count
	return v
