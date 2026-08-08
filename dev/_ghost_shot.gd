extends Node
# Throwaway visual check for DragGhost: the three context states of an armed rook's drag
# ghost (UNIT / CAST_OK / CAST_INVALID) plus a plain hand-card ghost, next to a real card
# for contrast. Run WITHOUT --headless (dummy renderer nulls SubViewport textures).
const OUT := "res://dev/_ghost_shot.png"
const RES := Vector2i(1700, 560)
const CARD_SIZE := Vector2(220.0, 288.0)


func _ready() -> void:
	GameData.select_slot(0)
	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = Color(0.18, 0.19, 0.22)
	sv.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 40)
	bg.add_child(row)
	row.position = Vector2(40, 48)

	# A real (non-ghost) card for contrast with the ghost fade.
	var real_ui := _rook_ui()
	row.add_child(_labeled("real card", real_ui))

	var pinned: Array = []   # [ [DragGhost, state], ... ] — applied after tree entry (see below)
	row.add_child(_labeled("ghost: default (red ability)", _ghost(_rook_ui(), -1, pinned)))
	row.add_child(_labeled("ghost: CAST_OK", _ghost(_rook_ui(), DragGhost.State.CAST_OK, pinned)))
	row.add_child(_labeled("ghost: UNIT (move)", _ghost(_rook_ui(), DragGhost.State.UNIT, pinned)))

	# A hand card (nothing armed): the ghost is always the plain faded unit copy.
	var pawn := CardInstance.from_data(CardData.get_card("pawn"))
	pawn.owner = 0
	var pawn_ui := CardUI.create(pawn, true)
	pawn_ui.custom_minimum_size = CARD_SIZE
	pawn_ui.size = CARD_SIZE
	row.add_child(_labeled("hand-card ghost", _ghost(pawn_ui, -1, pinned)))

	# Pin states only once the ghosts are in the tree: entering the tree re-enables _process
	# (undoing an early set_process(false)), whose stale-report fallback would instantly revert
	# any state pinned before that.
	await get_tree().process_frame
	for pair: Array in pinned:
		var g: DragGhost = pair[0]
		g.set_process(false)
		g._apply_state(pair[1] as DragGhost.State)

	for _i in 8:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED drag ghost states")
	get_tree().quit()


func _rook_ui() -> CardUI:
	var rook := CardInstance.from_data(CardData.get_card("rook"))
	rook.owner = 0
	rook.autocast_ability = "castling"
	var ui := CardUI.create(rook, false)
	ui.custom_minimum_size = CARD_SIZE
	ui.size = CARD_SIZE
	return ui


# Builds a ghost off `source`, queueing a state to pin post-tree-entry (-1 = default). The
# source CardUI must not be freed (DragGhost reads it at build time), so it's parked invisible.
func _ghost(source: CardUI, state: int, pinned: Array) -> Control:
	add_child(source)   # CardUI needs _ready to run before make_ghost_view copies it
	source.visible = false
	var ghost := DragGhost.make(source, Vector2.ZERO)
	ghost.custom_minimum_size = CARD_SIZE
	if state >= 0:
		pinned.append([ghost, state])
	return ghost


func _labeled(text: String, node: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	var lbl := Label.new()
	lbl.text = text
	box.add_child(lbl)
	node.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(node)
	return box
