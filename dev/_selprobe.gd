extends Node
# Throwaway probe: boots combat through the real Shell and drives REAL clicks (motion + press +
# release pushed into the viewport) so the whole gesture pipeline runs — Combat._input, the card's
# button press, the slot's relay. After each click it prints the pick and the hand panel's state,
# so any row where the pick names a unit while the panel is shut is a broken invariant.
# Run WITHOUT --headless:  godot --path . dev/_selprobe.tscn

var _combat: Node = null
var _slot: SlotUI = null


func _ready() -> void:
	var wd := Timer.new()
	wd.wait_time = 90.0
	wd.one_shot = true
	add_child(wd)
	wd.timeout.connect(func() -> void:
		print("PROBE WATCHDOG: giving up")
		get_tree().quit())
	wd.start()

	GameData.select_slot(0)
	GameData.start_new_run()
	var sv := SubViewport.new()
	sv.size = Vector2i(1920, 1080)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.auto_start = false
	sv.add_child(shell)
	shell.mount("res://scenes/combat.tscn")
	await get_tree().process_frame

	var combat: Node = null
	for n: Node in sv.find_children("*", "Node", true, false):
		if n.has_method("get_chrome") and n.get("_board") != null:
			combat = n
			break
	if combat == null:
		print("PROBE: no combat")
		get_tree().quit()
		return
	var board = combat.get("_board")
	var hand = combat.get("_hand")
	for _i in 30:
		await get_tree().process_frame

	var unit := CardInstance.from_data(CardData.get_card("rook"))
	board.spawn_player_card(unit, 2, 1)
	for _i in 5:
		await get_tree().process_frame

	_combat = combat
	var occupied: SlotUI = board.player_slots[2][1] as SlotUI
	_slot = occupied
	var empty: SlotUI = board.player_slots[0][2] as SlotUI
	var hand_card: CardUI = null
	for c: CardUI in hand.get("_hand_cards"):
		if c.card_instance == null or c.card_instance.is_spell:
			continue
		if hand_card == null or c.card_instance.get_attribute("cost") 				< hand_card.card_instance.get_attribute("cost"):
			hand_card = c
	if hand_card == null:
		print("PROBE: no hand card")
		get_tree().quit()
		return
	print("PROBE fielded=%s hand=%s" % [unit.data.id, hand_card.card_instance.data.id])
	_report("start", hand)

	var unit_at := occupied.get_global_rect().get_center()
	var hand_at := hand_card.get_global_rect().get_center()
	var empty_at := empty.get_global_rect().get_center()
	var dead := Vector2(20.0, 20.0)

	await _click(sv, unit_at);  _report("1 click the unit", hand)
	await _click(sv, dead);     _report("2 dead space", hand)
	await _click(sv, unit_at);  _report("3 the unit again", hand)
	await _click(sv, empty_at); _report("4 empty slot", hand)
	await _click(sv, unit_at);  _report("5 the unit again", hand)
	await _click(sv, dead);     _report("6 dead space", hand)
	await _click(sv, hand_at);  _report("7 a hand card", hand)
	await _click(sv, unit_at);  _report("8 the unit", hand)
	await _click(sv, hand_at);  _report("9 the hand card", hand)
	await _click(sv, hand_at);  _report("10 same card = never mind", hand)

	# ── The ability sub-pick: aim from the tray, panel must stay open on the holder ──
	await _click(sv, unit_at);  _report("11 the unit (panel opens)", hand)
	var tok: CardUI = null
	for g: CardUI in hand.get("_gen_cards"):
		tok = g
		break
	if tok == null:
		print("PROBE: no ability token in tray")
		get_tree().quit()
		return
	var tok_at := tok.get_global_rect().get_center()
	await _click(sv, tok_at)
	_report("12 click its ability token", hand)
	await _click(sv, tok_at)
	_report("13 same token = un-aim", hand)
	await _click(sv, tok_at)
	_report("14 aim it again", hand)
	await _click(sv, dead)
	_report("15 dead space (clears ALL)", hand)
	await _click(sv, unit_at)
	_report("16 the unit again", hand)

	# ── Click-placement must still commit through the dismissal guard ──
	await _click(sv, dead)      # close the panel so the hand row is back
	await _click(sv, hand_at)
	_report("17 hand card selected", hand)
	print("PROBE mana=%s cost=%s can_place=%s role=%s" % [
			_combat.get("_player_side").mana,
			hand_card.card_instance.get_attribute("cost"),
			board.can_place_from_hand(hand_card),
			_combat.get("_interaction").role_of(empty)])
	await _click(sv, empty_at)
	_report("18 empty slot = PLACE", hand)
	print("PROBE placed=%s" % (empty.get_card() != null))

	get_tree().quit()


# A REAL click at a screen point: motion first (so slot_at_mouse and hover agree with the press),
# then press + release through the viewport.
func _click(sv: SubViewport, at: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = at
	mm.global_position = at
	sv.push_input(mm)
	await get_tree().process_frame
	for down in [true, false]:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = down
		mb.position = at
		mb.global_position = at
		sv.push_input(mb)
		await get_tree().process_frame
	for _i in 3:
		await get_tree().process_frame


func _report(label: String, hand: Node) -> void:
	var sub: Variant = Selection.current()
	var name_of := "null"
	if sub is CardInstance:
		name_of = (sub as CardInstance).data.id
	var act: Variant = _combat.get("_interaction").current()
	var ab: Variant = Selection.current_ability()
	print("PROBE %-26s pick=%-9s ability=%-10s panel=%-5s shows_unit=%-5s aiming=%s" % [
			label, name_of,
			(ab as AbilityData).id if ab is AbilityData else "none",
			hand.get("_desc_panel").visible,
			hand.inspected_instance() != null,
			"none" if act == null else ("MODAL" if act.modal else "static")])
