extends Node
# Throwaway: renders the ground status TAB riding a slot's top border, in the geometry that
# matters — two stacked rows with the real SLOT_GAP gutter between them, so the icon overflow can
# be checked against the card in the row above. Covers: occupied (tab tucked behind the card),
# empty (whole tab visible), two statuses, and a mid-glint frame (the z lift).
# D:/Godot/Godot_v4.6.3-stable_win64_console.exe --path . res://dev/_ground_tab_shot.tscn
const OUT := "res://dev/_ground_tab_out.png"
const REF := "res://dev/_ground_tab_ref.png"   # the same board with NO ground, for measuring against


func _make_slot(row: int, col: int) -> SlotUI:
	var slot := SlotUI.new()
	slot.location = BoardLocation.at(0, row, col)
	slot.custom_minimum_size = Vector2(165, 216)
	return slot


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(900, 560)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = CombatBoard.PLAYER_ZONE_BG.blend(Color(0.10, 0.12, 0.22))
	bg.size = sv.size
	sv.add_child(bg)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.position = Vector2(24, 60)
	grid.add_theme_constant_override("h_separation", BoardData.SLOT_GAP)
	grid.add_theme_constant_override("v_separation", BoardData.SLOT_GAP)
	sv.add_child(grid)

	var slots: Array = []
	for r in 2:
		for c in 4:
			var slot := _make_slot(r, c)
			grid.add_child(slot)
			slots.append(slot)

	# Occupants everywhere except the last cell of each row, so a covered tab and a bare tab sit
	# side by side under the same light.
	var ids := ["pawn", "burning_pawn", "fire_knight", "pawn", "pawn", "burning_pawn", "pawn", "pawn"]
	for i in slots.size():
		if i == 3 or i == 7:
			continue
		var cd := CardData.get_card(ids[i])
		if cd == null:
			continue
		var inst := CardInstance.from_data(cd)
		inst.owner = 0
		(slots[i] as SlotUI).set_card(CardUI.create(inst))

	# The ground itself: burning on the whole bottom row plus two cells of the top row, and one
	# cell carrying a second status so a two-tab row can be judged.
	var grounds: Array = []
	for i in slots.size():
		var gs := BoardSlot.new()
		gs.side = 0
		gs.location = BoardLocation.at(0, int(i / 4), i % 4)
		grounds.append(gs)
		var slot := slots[i] as SlotUI
		slot.ground_lookup = func() -> BoardSlot: return gs
	for i in [1, 3, 4, 5, 6, 7]:
		StatusEngine.apply(grounds[i], "burning", Effect.STATUS_DURATION_DEFAULT, 2, null)
	StatusEngine.apply(grounds[5], "poison", 3, 2, null)

	await get_tree().process_frame
	await get_tree().process_frame
	# Vfx is an autoload and its overlay CanvasLayers hang off the root, OUTSIDE this SubViewport,
	# so the ground's spark stream would never reach the capture. Same reparent dev/_render.gd does.
	for vc: Node in Vfx.get_children().duplicate():
		if vc is CanvasLayer:
			Vfx.remove_child(vc)
			sv.add_child(vc)
	for slot: SlotUI in slots:
		slot.render_ground()

	await get_tree().process_frame
	await get_tree().process_frame
	# A glint in flight on an OCCUPIED slot — the frame that proves the lift clears the card —
	# and the ground flare that rides with it.
	var pip := (slots[4] as SlotUI).find_ground_pip("burning")
	if pip != null:
		pip.flash_proc()
	(slots[4] as SlotUI).flare_ground("burning")
	for _i in 9:
		await get_tree().process_frame

	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ground tabs")

	# The REFERENCE frame: the same board with the ground cleared, for measuring the frame and the
	# floor wash against instead of eyeballing them (warm card art reads as tinted when it isn't —
	# an hour was lost to exactly that in the rim's day).
	for gs: BoardSlot in grounds:
		gs.statuses.clear()
	for slot: SlotUI in slots:
		slot.render_ground()
	for _i in 4:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(REF)
	print("RENDERED ground reference")
	get_tree().quit()
