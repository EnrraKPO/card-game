extends Node
# Throwaway: the health gauge across the states that matter — full, wounded, nearly dead, and a
# big pool (where the chunk stack gives way to the solid bar) — at board size and at hand size.
#   godot --path . res://dev/_health_gauge_shot.tscn ; view dev/_health_gauge_out.png
const OUT := "res://dev/_health_gauge_out.png"
const BOARD_W := 176.0   # about what a board slot gives a card in a 1920-wide fight
const HAND_W := 150.0


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1500, 760)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = Color(0.18, 0.20, 0.34)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(bg)

	var rows := VBoxContainer.new()
	rows.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rows.add_theme_constant_override("separation", 24)
	sv.add_child(rows)

	# id, health left, and the width to draw at.
	for spec: Array in [["pawn", BOARD_W], ["king", BOARD_W], ["pawn", HAND_W]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 22)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		rows.add_child(row)
		var card_id: String = spec[0]
		var w: float = spec[1]
		var base := CardInstance.from_data(CardData.get_card(card_id))
		var full := base.get_attribute("max_health")
		for frac: float in [1.0, 0.7, 0.4, 0.1]:
			var inst := CardInstance.from_data(CardData.get_card(card_id))
			inst.current_health = maxi(1, int(round(full * frac)))
			var ui := CardUI.create(inst)
			ui.custom_minimum_size = Vector2(w, w * 340.0 / 260.0)
			row.add_child(ui)

	for _i in 12:
		await get_tree().process_frame
	var img := sv.get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(OUT))
	print("RENDERED health gauge states")
	get_tree().quit(0)
