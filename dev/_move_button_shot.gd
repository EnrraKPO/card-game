extends Node
# Throwaway: renders the move button's states side by side for eyeballing — including a slot
# with the ghost phantom mounted, to prove the button reads OVER the card (badges live at z 60).
# godot --path . res://dev/_move_button_shot.tscn ; view _move_button_out.png
const OUT := "res://dev/_move_button_out.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1400, 320)
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

	# [label, open_cue, button, hover, progress, phantom]
	var states := [
		["OPEN marker", true, false, false, 0.0, false],
		["BUTTON idle", false, true, false, 0.0, false],
		["BUTTON hover", false, true, true, 0.0, false],
		["hold 55%", false, true, true, 0.55, false],
		["hover + ghost", false, true, true, 0.0, true],
		["hold 55% + ghost", false, true, true, 0.55, true],
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
		slots.append([slot, st])

	await get_tree().process_frame
	await get_tree().process_frame
	for entry: Array in slots:
		var slot := entry[0] as SlotUI
		var st: Array = entry[1]
		if bool(st[1]):
			slot.set_cue(SlotUI.Cue.OPEN)
			continue
		slot.set_cue(SlotUI.Cue.MOVE, false)
		slot.set_move_button(bool(st[2]))
		if bool(st[5]):
			var src := CardUI.create(CardInstance.from_data(CardData.get_card("king")))
			slot.mount_phantom(src.make_ghost_view())
		if bool(st[3]):
			slot._move_btn._set_hover(true)
		if float(st[4]) > 0.0:
			slot._move_btn._progress = float(st[4])
			slot._move_btn.queue_redraw()
	# Let the bob tween advance to a dipped frame before capture.
	for i in 25:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED move button states")
	get_tree().quit()
