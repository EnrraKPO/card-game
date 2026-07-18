extends Node
# Throwaway visual check: the CardTooltip (shared by hover + CardInspector) for a rook with
# Castling ARMED — the abilities section should show a small ability widget beside the
# description. Run WITHOUT --headless.
const OUT := "res://_tooltip_shot.png"
const RES := Vector2i(1500, 720)


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

	var rook := CardInstance.from_data(CardData.get_card("rook"))
	rook.owner = 0
	rook.row = 1
	rook.col = 1
	rook.autocast_ability = "castling"

	var pawn := CardInstance.from_data(CardData.get_card("air_fire_king"))
	pawn.owner = 0

	# CenterContainer sizes each child to its MINIMUM size — the same thing the tooltip popup
	# does — so any phantom empty space shows up here exactly as it would in-game.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 30)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(center)
	center.add_child(row)
	row.add_child(CardTooltip.build(rook, false))
	row.add_child(CardTooltip.build(pawn, true))
	# A native-tooltip body sample (what TipButton/TipPanel hovers pop), keyword-rich.
	var tip := TextIcons.tooltip_body(
		"Septic Ward — when a rook or bishop dies from poison, your king gains 2 shield.")
	row.add_child(tip)

	for _i in 8:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED tooltip")
	get_tree().quit()
