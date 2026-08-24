extends Node
# Renders the test suite inspector after a full run — the settings-menu surface, verdicts in.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_tests_shot.tscn
const OUT := "res://dev/_tests_out.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1422, 800)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(host)
	await get_tree().process_frame
	var overlay := TestSuiteOverlay.open(host)
	await get_tree().process_frame
	overlay._run()
	var waited := 0.0
	while overlay._thread != null and waited < 420.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	await get_tree().process_frame
	await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED test suite inspector (waited %.1fs)" % waited)
	get_tree().quit()
