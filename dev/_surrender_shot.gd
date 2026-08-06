extends Node
# Probe for the surrender beat: stages a real combat, fires the captain's surrender
# directly (the same _surrender_captain the empty-plan gate calls), and captures the
# speech bubble + tremble mid-beat.
#
#   godot --path . res://dev/_surrender_shot.tscn -- [at=0.9] [WxH]
#
# Writes res://dev/_render_out.png (gitignored scratch, like the rest of dev/).
# Run WITHOUT --headless — the capture needs a real renderer.

const OUT := "res://dev/_render_out.png"
var RES := Vector2i(1920, 1080)


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var at := 0.9
	for a: String in args:
		if a.begins_with("at="):
			at = float(a.trim_prefix("at="))
		elif a.contains("x") and a.split("x")[0].is_valid_int():
			RES = Vector2i(int(a.split("x")[0]), int(a.split("x")[1]))
	GameData.select_slot(0)
	GameData.start_new_run()

	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.auto_start = false
	sv.add_child(shell)
	shell.mount("res://scenes/combat.tscn")
	await get_tree().process_frame
	await get_tree().process_frame

	var combat: Node = null
	for n: Node in sv.find_children("*", "Node", true, false):
		if n.has_method("get_chrome") and n.get("_board") != null:
			combat = n
			break
	if combat == null:
		push_error("probe: no combat screen found")
		get_tree().quit(1)
		return

	# Fire the beat and shoot it mid-flight (arrival is ~0.3s, the hold ~1.7s).
	combat.call("_surrender_captain")
	await get_tree().create_timer(at).timeout
	await RenderingServer.frame_post_draw
	sv.get_texture().get_image().save_png(OUT)
	print("wrote ", OUT, " at t=", at)
	get_tree().quit()
