extends Node
# Reproduces the reported miss: boots the fight, selects a player unit through the real
# click path, waits past the self-poll, and reports every link of the selection chain.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_selection_probe.tscn
const OUT := "res://dev/_selection_out.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1422, 800)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var screen := FightScreen.new()
	sv.add_child(screen)
	screen.size = sv.size
	await get_tree().create_timer(1.5).timeout
	# Find the player king's slot and click it through the real handler.
	var unit: Unit = null
	var address := Vector3i(-1, -1, -1)
	for row: int in BoardGeometry.ROWS:
		for col: int in BoardGeometry.COLS:
			var a := Vector3i(0, row, col)
			var found: Unit = SlotViewModel.occupant(screen.world.board_manager.slot_at(a))
			if found != null and unit == null:
				unit = found
				address = a
	print("PROBE unit=", unit, " span=", screen._span_active, " awaiting=",
			screen._awaiting_command)
	screen._on_slot_clicked(address)
	print("PROBE selection holds unit: ", Selection.holds(unit))
	await get_tree().create_timer(1.2).timeout   # past the 0.75s self-poll
	var card: CardUI = screen._card_uis.get(unit)
	if card != null:
		print("PROBE card selected_now=", card._selected_now,
				" pickable=", card._pickable(),
				" subject_is_unit=", card.subject() == unit,
				" scale=", card.scale)
	else:
		print("PROBE no card ui for unit")
	sv.get_texture().get_image().save_png(OUT)
	print("PROBE rendered")
	get_tree().quit()
