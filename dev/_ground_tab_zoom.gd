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
		slot.location = BoardLocation.at(0, int(i / 3), i % 3)
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
		# BOTTOM-RIGHT card GROWN (slot 5: occupied, burning, and inside this crop), as the selection
		# highlight grows one
		# — the case the ground row has to follow. Two things are on trial here: the row scaling and
		# rising in step with the card (staying proportionally visible above its top edge), and the
		# draw order where that rise intrudes ~5px into the card in the row ABOVE. Grid children are
		# added top row first, so the lower slot draws later and its tabs should land OVER that
		# neighbour. Grown past the authored 1.07 to make both effects unambiguous at a glance.
		if i == 5:
			ui.pivot_offset = Vector2(165, 216) * 0.5
			ui.scale = Vector2(1.12, 1.12)

	var grounds: Array = []
	for i in 6:
		var gs := BoardSlot.new()
		gs.side = 0
		gs.location = BoardLocation.at(0, int(i / 3), i % 3)
		grounds.append(gs)
		(slots[i] as SlotUI).ground_lookup = func() -> BoardSlot: return gs
	# A hit's worth (2 stacks) on the occupied and empty cells; a heavy 6-stack pile on the
	# glint cell so the shrink-to-fit path is on screen too.
	# A SINGLE stack on the top row: the lone-tab case, which is the one the width fraction names
	# directly ("slightly over half the tile"). Every other count falls out of the equal share.
	StatusEngine.apply(grounds[0], "burning", Effect.STATUS_DURATION_DEFAULT, 1, null)
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

	# MEASURED, not eyeballed: the row's rect at rest vs grown, against the card it might intrude on.
	# (Rects are in the 4x-scaled grid's space — ratios and the overlap verdict are what matter.)
	var rest_row := (slots[4] as SlotUI)._ground_pips.get_global_rect()
	var grown_row := (slots[5] as SlotUI)._ground_pips.get_global_rect()
	var above := (slots[2] as SlotUI).get_card().get_global_rect()
	print("rest row   top=%.1f h=%.1f" % [rest_row.position.y, rest_row.size.y])
	print("grown row  top=%.1f h=%.1f  (scale %.3f, rose %.1f)"
			% [grown_row.position.y, grown_row.size.y,
			grown_row.size.y / rest_row.size.y, rest_row.position.y - grown_row.position.y])
	print("card above bottom=%.1f -> clearance rest=%.1f grown=%.1f"
			% [above.end.y, rest_row.position.y - above.end.y, grown_row.position.y - above.end.y])
	# Tab width as a share of the slot it sits on, at 1 / 2 / 12 tabs (slots 3, 4 and 5 carry
	# 2, 4 and 12 stacks; slot 0 is unburnt). Divided by ZOOM to read as authored pixels.
	for idx in [0, 3, 4, 5]:
		var s := slots[idx] as SlotUI
		var row := s._ground_pips
		if row.get_child_count() > 0:
			var tab := (row.get_child(0) as Control).size.x
			print("slot %d: %d tabs, tab w=%.0f of slot %.0f = %.1f%%  (icon strip above slot top=%.1f)"
					% [idx, row.get_child_count(), tab, s.size.x, 100.0 * tab / s.size.x,
					SlotUI.GROUND_ROW_RISE])

	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ground tab zoom")
	get_tree().quit()
