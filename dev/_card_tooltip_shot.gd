extends Node
# Renders the card details read with injected status views — the tooltip half of R6.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_card_tooltip_shot.tscn
const OUT := "res://dev/_card_tooltip_out.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(900, 560)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.11)
	bg.size = sv.size
	sv.add_child(bg)

	var data := CardData.new()
	data.display_name = "Squire"
	data.cost = 2
	data.attack = 3
	data.health = 5
	data.speed = 2
	data.shield = 1
	var poison := StatusPipView.new()
	poison.id = "poison"
	poison.display_name = "Poison"
	poison.color = Color(0.45, 0.75, 0.2)
	poison.count = 3
	poison.stacks = 3
	poison.description = "Takes damage per stack when it acts."
	var gloom := StatusPipView.new()
	gloom.id = "gloom"
	gloom.display_name = "Gloom"
	gloom.color = Color(0.5, 0.4, 0.7)

	var statuses: Array[StatusPipView] = [poison, gloom]
	var panel := CardTooltip.build(data, true, 1.0, false, true, false, statuses)
	panel.position = Vector2(30, 30)
	sv.add_child(panel)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED card tooltip with statuses")
	get_tree().quit()
