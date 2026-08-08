extends Node
# Throwaway diagnostic: boots real combat, selects a fielded unit through the real click
# handler, commits a move through the move button's path, and reports what happens to the
# Selection at each step. godot --path . res://dev/_move_select_probe.tscn
func _ready() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()
	var combat: Node = (load("res://scenes/combat.tscn") as PackedScene).instantiate()
	add_child(combat)

	# Wait for setup: the board exists and placement input is live.
	var board: Node = null
	for _w in 300:
		await get_tree().process_frame
		board = combat.get("_board")
		if board != null and bool(board.get("placement_enabled")):
			break
	if board == null or not bool(board.get("placement_enabled")):
		print("PROBE: combat never reached placement — board=%s" % [board])
		get_tree().quit()
		return

	var atk := CardInstance.from_data(CardData.get_card("bishop"))
	board.spawn_player_card(atk, BoardLocation.at(0, 1, 3))
	await get_tree().process_frame

	var src_slot: SlotUI = board.player_slots[1][3]
	combat._on_board_slot_pressed(src_slot)
	await get_tree().process_frame
	var dest: SlotUI = board.player_slots[1][1]
	print("PROBE after select: holds=%s action=%s dest_button=%s" % [
			Selection.holds(atk), board.interaction.active(), dest._move_btn.visible])

	var ui: CardUI = board.get_card_ui(atk)
	await get_tree().process_frame
	var key_before: bool = Vfx._attached.has(Vfx._attach_key("highlight", ui))

	board._on_move_button_pressed(dest)
	await get_tree().process_frame
	await get_tree().process_frame
	var key_after: bool = Vfx._attached.has(Vfx._attach_key("highlight", ui))
	print("PROBE after commit: holds=%s action=%s moved=%s src_empty=%s" % [
			Selection.holds(atk), board.interaction.active(),
			dest.get_card() != null and dest.get_card().card_instance == atk,
			src_slot.get_card() == null])
	print("PROBE highlight vfx: before=%s after=%s" % [key_before, key_after])
	# The re-presented action must describe the NEW spot (stale = old row/col declaration).
	print("PROBE preview pivot at: %s — unit at %s" % [
			str(board._pivot_at), str(board.world.location_of(atk))])

	# The release lands on the moved card (cursor sat on the button): CardUI re-emits pressed.
	combat._on_board_slot_pressed(dest)
	await get_tree().process_frame
	print("PROBE after release-press: holds=%s action=%s" % [
			Selection.holds(atk), board.interaction.active()])
	# What the re-derived action offers now (buttons on the new destinations?).
	print("PROBE buttons visible after move: %d" % _count_buttons(board))

	# The no-op drag: pick the unit up and put it back down on its own slot (drop rejected,
	# nothing moves). The static selection UI must derive right back.
	var moved_ui: CardUI = board.get_card_ui(atk)
	board._on_unit_drag_started(moved_ui)
	await get_tree().process_frame
	print("PROBE during drag: action=%s buttons=%d" % [
			board.interaction.active(), _count_buttons(board)])
	board._on_unit_drag_ended(moved_ui)
	await get_tree().process_frame
	print("PROBE after no-op drag: holds=%s action=%s buttons=%d" % [
			Selection.holds(atk), board.interaction.active(), _count_buttons(board)])
	get_tree().quit()


func _count_buttons(board: Node) -> int:
	var buttons := 0
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if (board.player_slots[r][c] as SlotUI)._move_btn.visible:
				buttons += 1
	return buttons
