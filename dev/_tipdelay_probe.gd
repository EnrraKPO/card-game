extends Node
# Throwaway diagnostic: can the native tooltip's delay be changed at RUNTIME, and can a probe
# make a real tooltip pop at all? Run WITHOUT --headless.
#   godot --path D:\Godot\CardGame res://dev/_tipdelay_probe.tscn

func _ready() -> void:
	print("SETTING now = ", ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", -1.0))
	var vp := get_viewport()
	for p: Dictionary in vp.get_property_list():
		if "tooltip" in str(p.get("name", "")).to_lower():
			print("VIEWPORT PROPERTY: ", p)
	print("Viewport has set_tooltip_delay: ", vp.has_method("set_tooltip_delay"))

	# A trivial hover target of our own — no game, no board, nothing to get in the way.
	var btn := Button.new()
	btn.text = "hover me"
	btn.tooltip_text = "a tip"
	btn.size = Vector2(300, 120)
	btn.position = Vector2(200, 200)
	add_child(btn)
	await get_tree().process_frame

	DisplayServer.window_move_to_foreground()
	await get_tree().create_timer(0.3).timeout

	for attempt: String in ["warp+motion", "motion only", "after delay change"]:
		if attempt == "after delay change":
			ProjectSettings.set_setting("gui/timers/tooltip_delay_sec", 0.05)
			print("SETTING changed to ",
					ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", -1.0))
		var at := btn.get_global_rect().get_center()
		if attempt == "warp+motion":
			Input.warp_mouse(at)
		var ev := InputEventMouseMotion.new()
		ev.position = at
		ev.global_position = at
		get_viewport().push_input(ev)

		var popped := -1.0
		var t := 0.0
		for i in 200:
			await get_tree().process_frame
			t += get_process_delta_time()
			if _tooltip_window() != null:
				popped = t
				break
		print("ATTEMPT %s: popped=%s after %.2fs  (hover=%s)" % [attempt, popped >= 0.0, popped,
				get_viewport().gui_get_hovered_control()])
		# Clear it before the next attempt.
		var ev2 := InputEventMouseMotion.new()
		ev2.position = Vector2(900, 900)
		ev2.global_position = Vector2(900, 900)
		get_viewport().push_input(ev2)
		await get_tree().create_timer(0.2).timeout
	get_tree().quit()


func _tooltip_window() -> Window:
	for w in get_tree().root.get_children():
		if w is PopupPanel and (w as Window).visible:
			return w as Window
	return null
