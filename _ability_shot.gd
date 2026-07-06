extends Node
# Throwaway visual check for AbilityWidget + autocast brackets: renders three widget states
# (non-autocast material, capable-but-off, armed) and the board-side armed echo to a PNG.
const OUT := "res://_ability_shot.png"
const RES := Vector2i(1400, 560)


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
	row.add_theme_constant_override("separation", 48)
	bg.add_child(row)
	row.position = Vector2(48, 48)

	var castling := AbilityData.get_ability("castling")
	var pawn_mat := AbilityData.get_ability("pawn_material")

	var holder_off := _fielded_rook()
	var holder_armed := _fielded_rook()
	holder_armed.autocast_ability = "castling"

	row.add_child(_labeled("no autocast (material)", _widget(pawn_mat, holder_off)))
	row.add_child(_labeled("capable, OFF", _widget(castling, holder_off)))
	row.add_child(_labeled("ARMED", _widget(castling, holder_armed)))

	var board_card := CardUI.create(holder_armed, false)
	board_card.custom_minimum_size = Vector2(165, 216)
	row.add_child(_labeled("board echo (armed)", board_card))

	for _i in 8:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED ability widget states")
	get_tree().quit()


func _fielded_rook() -> CardInstance:
	var inst := CardInstance.from_data(CardData.get_card("rook"))
	inst.owner = 0
	inst.row = 1
	inst.col = 1
	return inst


func _widget(ab: AbilityData, holder: CardInstance) -> Control:
	var tok := CardInstance.from_data(ab.display_card())
	tok.owner = 0
	tok.row = -1
	tok.col = -1
	tok.source_building = holder
	tok.ability = ab
	var w := AbilityWidget.create_for(tok)
	w.custom_minimum_size = Vector2(220, 288)
	return w


func _labeled(text: String, node: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	var lbl := Label.new()
	lbl.text = text
	box.add_child(lbl)
	node.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(node)
	return box
