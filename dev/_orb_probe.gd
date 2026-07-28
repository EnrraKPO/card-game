extends Node
# Throwaway probe: plays the real reward_orb effect against a stand-in chest and saves a FRAME
# SEQUENCE of the arrival detonation, so the burst's read can be judged frame by frame — a single
# screenshot cannot tell "no explosion" apart from "explosion lived for two frames".
# Run WITHOUT --headless:  godot --path . res://dev/_orb_probe.tscn

const OUT_DIR := "res://dev/_orb_probe_out"

var _arrived := false


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(960, 540)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.12)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(bg)
	# The chest stand-in sits where the real one does: the enemy king's slot, top of the board.
	var chest := ColorRect.new()
	chest.color = Color(0.35, 0.25, 0.12)
	chest.position = Vector2(430, 40)
	chest.size = Vector2(100, 80)
	sv.add_child(chest)
	await get_tree().process_frame

	# A Shell stand-in registered with Nav, so the burst's adopt_underlay handoff runs for real:
	# the detonation must land UNDER the modal added later, exactly as it does under the Shell's
	# content row in the game.
	var stub := _ShellStub.new()
	stub.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(stub)
	Nav.register_shell(stub)

	Vfx.register_custom("reward_orb", RewardOrbFx.play)
	# On arrival a stand-in modal grows exactly like screen_grow_in (0.2s hold, 0.25s pop), so
	# the frames show the composite read under judgement: does the screen pop from INSIDE the blast?
	Vfx.play("reward_orb", chest, {"on_arrive": func() -> void:
		_arrived = true
		_pop_modal(stub)})
	# The orb hangs off Vfx's overlay CanvasLayers, outside this SubViewport — pull them in
	# (same trick as dev/_render.gd) or the capture never sees it.
	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			sv.add_child(vc)

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var shot := 0
	var frame := 0
	# One context frame mid-flight, then the burst itself sampled every 3 frames (~0.05s at 60fps)
	# from the moment on_arrive fires until well past the linger.
	while not _arrived and frame < 400:
		frame += 1
		await get_tree().process_frame
		if frame == 30:
			sv.get_texture().get_image().save_png("%s/flight.png" % OUT_DIR)
	for i in 42:
		if i % 3 == 0:
			sv.get_texture().get_image().save_png("%s/burst_%02d.png" % [OUT_DIR, shot])
			shot += 1
		await get_tree().process_frame
	print("ORB PROBE: arrived=%s, %d burst frames -> %s" % [_arrived, shot, OUT_DIR])
	get_tree().quit()


func _pop_modal(host: Control) -> void:
	var m := ColorRect.new()
	m.color = Color(0.16, 0.18, 0.24)
	m.size = Vector2(720, 420)
	m.position = (Vector2(960, 540) - m.size) * 0.5
	m.pivot_offset = m.size * 0.5
	m.scale = Vector2.ZERO
	host.add_child(m)
	var tw := m.create_tween()
	tw.tween_interval(0.2)
	tw.tween_property(m, "scale", Vector2.ONE, 0.25) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Mirrors Shell.adopt_underlay's contract: the burst lands below whatever the host mounts later.
class _ShellStub extends Control:
	func adopt_underlay(fx: Control) -> void:
		fx.z_index = 0
		fx.reparent(self)
		move_child(fx, 0)
