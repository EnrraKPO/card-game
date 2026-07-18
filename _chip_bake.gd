extends Node
# Asset bake, rerun when the chip style changes: renders CardUI's composition chips (the real
# _make_comp_chip control, outline shader and all) to PNGs for TextIcons' inline rules-text
# icons. 4x native chip size for crispness when scaled into text. Run WITHOUT --headless.
const OUT_DIR := "res://assets/ui/icons/text/"
const SCALE := 4.0
const NATIVE := 36

const ELEMENTS := ["air", "darkness", "earth", "fire", "light", "water"]
const PIECES := ["pawn", "bishop", "knight", "rook", "queen", "king"]


func _ready() -> void:
	var px := int(NATIVE * SCALE)
	var views: Dictionary = {}
	for comp_id: String in ELEMENTS + PIECES:
		var sv := SubViewport.new()
		sv.size = Vector2i(px, px)
		sv.transparent_bg = true
		sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(sv)
		var chip := CardUI._make_comp_chip(comp_id, comp_id in ELEMENTS)
		chip.scale = Vector2(SCALE, SCALE)
		sv.add_child(chip)
		chip.size = Vector2(NATIVE, NATIVE)
		chip.position = Vector2.ZERO
		views[comp_id] = sv

	for _i in 8:
		await get_tree().process_frame
	for comp_id: String in views:
		var sv: SubViewport = views[comp_id]
		sv.get_texture().get_image().save_png(OUT_DIR + comp_id + ".png")
	print("BAKED %d chips" % views.size())
	get_tree().quit()
