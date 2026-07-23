extends Node
# Throwaway: renders each SlotUI cue state side by side so the glyphs can be eyeballed.
# godot --headless --path . res://_slot_cue_shot.tscn ; view _slot_cue_out.png
const OUT := "res://_slot_cue_out.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1180, 320)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.12, 0.22)
	bg.size = sv.size
	sv.add_child(bg)

	var row := HBoxContainer.new()
	row.position = Vector2(24, 40)
	row.add_theme_constant_override("separation", 24)
	sv.add_child(row)

	var states := [
		["OPEN", SlotUI.Cue.OPEN, false],
		["MOVE (static)", SlotUI.Cue.MOVE, false],
		["MOVE (bob)", SlotUI.Cue.MOVE, true],
		["TARGET_OK", SlotUI.Cue.TARGET_OK, false],
		["TARGET_BAD", SlotUI.Cue.TARGET_BAD, false],
	]
	var slots: Array = []
	for st: Array in states:
		var box := VBoxContainer.new()
		row.add_child(box)
		var lbl := Label.new()
		lbl.text = st[0]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(lbl)
		var slot := SlotUI.new()
		slot.owner_id = 0
		slot.custom_minimum_size = Vector2(165, 216)
		box.add_child(slot)
		slots.append([slot, st[1], st[2]])

	await get_tree().process_frame
	await get_tree().process_frame
	for entry: Array in slots:
		(entry[0] as SlotUI).set_cue(entry[1], entry[2])
	# Let the bob tween advance to a dipped frame before capture.
	for i in 25:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED slot cues")
	get_tree().quit()
