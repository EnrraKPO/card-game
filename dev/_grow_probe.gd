extends Node
# Throwaway probe for the MODAL arrival: mounts combat, then navigates to the reward screen the
# way a win does (Shell.mount(path, "screen_grow_in")) and checks that the combat screen is still
# mounted and drawing underneath while the modal grows. Saves two PNGs mid-arrival.
# Run WITHOUT --headless.
const RES := Vector2i(1920, 1080)


func _ready() -> void:
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
	for _i in 20:
		await get_tree().process_frame

	shell.mount("res://scenes/reward_screen.tscn", "screen_grow_in")

	var lower: Node = shell._lower_area
	var shot := 0
	var t := 0.0
	while t < 2.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var dep: Node = shell._departing
		var plate: Node = shell._modal_plate
		var stage: Control = lower.get_child(lower.get_child_count() - 1) as Control
		print("t=%.2f  departing=%s dim=%.2f  plate=%.2f  modal=%.2f/%.2f  children=%d"
				% [t, "LIVE" if (dep != null and is_instance_valid(dep)) else "gone",
				(dep.modulate.r if (dep != null and is_instance_valid(dep)) else -1.0),
				(plate.scale.x if (plate != null and is_instance_valid(plate)) else -1.0),
				stage.scale.x, stage.modulate.a, lower.get_child_count()])
		# Two captures: one while the modal is opening, one once it has landed.
		if shot == 0 and stage.scale.x > 0.35 and stage.scale.x < 0.8:
			sv.get_texture().get_image().save_png("res://dev/_modal_opening.png")
			shot = 1
		elif shot == 1 and t > 1.6:
			sv.get_texture().get_image().save_png("res://dev/_modal_landed.png")
			shot = 2
	get_tree().quit()
