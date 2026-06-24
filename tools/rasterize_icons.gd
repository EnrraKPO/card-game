# Headless: rasterize the icon SVGs to PNG via Godot's own SVG renderer.
# Run: godot --headless --path D:/Godot/CardGame --script res://tools/rasterize_icons.gd
extends SceneTree

func _initialize() -> void:
	var src_dir := "res://assets/ui/icons/"
	var out_dir := "res://tools/_icon_preview/raw/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var d := DirAccess.open(src_dir)
	var scale := 4.0  # 64 -> 256px masters
	for f in d.get_files():
		if not f.ends_with(".svg"):
			continue
		var txt := FileAccess.get_file_as_string(src_dir + f)
		var img := Image.new()
		var err := img.load_svg_from_string(txt, scale)
		if err != OK:
			push_error("failed: %s (%d)" % [f, err])
			continue
		img.save_png(out_dir + f.get_basename() + ".png")
		print("rasterized ", f)
	quit()
