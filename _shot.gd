extends SceneTree
func _init() -> void:
	root.size = Vector2i(1280, 720)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.14)
	bg.size = Vector2(1280, 720)
	root.add_child(bg)
	var b := Button.new()
	b.text = "Big Button Test"
	b.add_theme_font_size_override("font_size", 64)
	b.position = Vector2(220, 260)
	b.custom_minimum_size = Vector2(820, 200)
	root.add_child(b)
	_run()
func _run() -> void:
	await process_frame
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	if img == null:
		print("IMG NULL"); quit(); return
	img.save_png("res://_shot_out.png")
	print("SAVED ", img.get_size())
	quit()
