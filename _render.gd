extends Node
# Throwaway render harness: boots autoloads + a real save, renders a screen (passed after `--`) into
# an exact-size SubViewport, saves a PNG. e.g. godot --path . res://_render.tscn -- res://scenes/X.tscn
const OUT := "res://_render_out.png"
const RES := Vector2i(1920, 1080)
func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else "res://scenes/game_world.tscn"
	GameData.select_slot(0)
	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	sv.add_child(load(scene_path).instantiate())
	for i in 8:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ", scene_path, " @ ", RES)
	get_tree().quit()
