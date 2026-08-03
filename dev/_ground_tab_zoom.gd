extends Node
# Throwaway companion to _ground_tab_shot: the same tabs at 2.4x so the occlusion can be MEASURED
# rather than eyeballed — occupied vs empty side by side, plus a held glint frame.
# D:/Godot/Godot_v4.6.3-stable_win64_console.exe --path . res://dev/_ground_tab_zoom.tscn
const OUT := "res://dev/_ground_tab_zoom_out.png"
const ZOOM := 4.0


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1300, 700)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = CombatBoard.PLAYER_ZONE_BG.blend(Color(0.10, 0.12, 0.22))
	bg.size = sv.size
	sv.add_child(bg)

	var grid := GridContainer.new()
	grid.columns = 3
	# Framed on the SEAM: the bottom of the top row's cards, the gutter, and the top of the
	# bottom row's slots — the band where the whole question lives.
	grid.position = Vector2(-680, -700)
	grid.scale = Vector2(ZOOM, ZOOM)
	grid.add_theme_constant_override("h_separation", BoardData.SLOT_GAP)
	grid.add_theme_constant_override("v_separation", BoardData.SLOT_GAP)
	sv.add_child(grid)

	var slots: Array = []
	for i in 6:
		var slot := SlotUI.new()
		slot.owner_id = 0
		slot.row = int(i / 3)
		slot.col = i % 3
		slot.custom_minimum_size = Vector2(165, 216)
		grid.add_child(slot)
		slots.append(slot)

	# Top row: cards to be covered BY (they sit above the bottom row's tabs).
	# Bottom row: 0 = occupied + burning, 1 = empty + burning, 2 = occupied + burning, glinting.
	for i in [0, 1, 2, 3, 5]:
		var cd := CardData.get_card("pawn")
		var inst := CardInstance.from_data(cd)
		inst.owner = 0
		var ui := CardUI.create(inst)
		(slots[i] as SlotUI).set_card(ui)
		# Top-left card GROWN, as the selection highlight grows one — the case that decides whether a
		# neighbouring slot's ground frame can cut a piece. Sibling slots paint in row-major order, so
		# the bottom row's frame is drawn AFTER this card and would slice whatever overflows into the
		# gutter. (An un-grown card is exactly its slot, so nothing overflows and the question hides.)
		if i == 0:
			ui.pivot_offset = Vector2(165, 216) * 0.5
			ui.scale = Vector2(1.12, 1.12)

	var grounds: Array = []
	for i in 6:
		var gs := BoardSlot.new()
		gs.side = 0
		gs.row = int(i / 3)
		gs.col = i % 3
		grounds.append(gs)
		(slots[i] as SlotUI).ground_lookup = func() -> BoardSlot: return gs
	# A hit's worth (2 stacks) on the occupied and empty cells; a heavy 6-stack pile on the
	# glint cell so the shrink-to-fit path is on screen too.
	StatusEngine.apply(grounds[3], "burning", Effect.STATUS_DURATION_DEFAULT, 2, null)
	StatusEngine.apply(grounds[4], "burning", Effect.STATUS_DURATION_DEFAULT, 4, null)
	StatusEngine.apply(grounds[5], "burning", Effect.STATUS_DURATION_DEFAULT, 12, null)

	await get_tree().process_frame
	await get_tree().process_frame
	# Vfx's overlay CanvasLayers hang off the root, outside this SubViewport — reparent them in or
	# the spark stream never reaches the capture (same move dev/_render.gd makes).
	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			sv.add_child(vc)
	for slot: SlotUI in slots:
		slot.render_ground()

	await get_tree().process_frame
	await get_tree().process_frame
	# GLINT=1 in the environment holds a mid-flash frame on the LEFT occupied slot instead of the
	# resting look, so the lift over the card can be judged at the same magnification.
	if OS.get_environment("GLINT") == "1":
		var pip := (slots[3] as SlotUI).find_ground_pip("burning")
		if pip != null:
			pip.flash_proc()
		for _i in 7:
			await get_tree().process_frame

	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ground tab zoom")
	get_tree().quit()
