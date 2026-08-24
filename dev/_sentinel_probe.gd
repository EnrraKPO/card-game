extends Node
# Diagnoses the oversized enemy Sentinel: prints the card widget's geometry vs its slot.
func _ready() -> void:
	var screen := FightScreen.new()
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Pass turns until the enemy fields its Sentinel (it needs round-2 mana).
	for _round: int in 3:
		while not (screen._span_active and screen._awaiting_command):
			await get_tree().create_timer(0.2).timeout
		screen.commanded.emit(null)
		await get_tree().create_timer(0.5).timeout
	await get_tree().create_timer(1.0).timeout
	for address: Vector3i in screen._slot_uis:
		var unit: Unit = SlotViewModel.occupant(screen.world.board_manager.slot_at(address))
		if unit == null:
			continue
		var ui: CardUI = screen._card_uis.get(unit)
		var slot: SlotUI = screen._slot_uis[address]
		print("PROBE ", unit.display_name, " at ", address,
				" slot_size=", slot.size,
				" card_size=", ui.size, " card_min=", ui.custom_minimum_size,
				" card_scale=", ui.scale, " card_pos=", ui.position,
				" parent_is_slot=", ui.get_parent() == slot,
				" anchors=", Vector4(ui.anchor_left, ui.anchor_top, ui.anchor_right,
						ui.anchor_bottom),
				" offsets=", Vector4(ui.offset_left, ui.offset_top, ui.offset_right,
						ui.offset_bottom))
	get_tree().quit()
