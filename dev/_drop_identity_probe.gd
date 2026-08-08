extends Node
# Throwaway: does a drop commit the gesture that STARTED it, or whatever action happens to be
# live? Godot asks the control under the cursor, not the card being dragged — so the question is
# whether Interaction checks identity anywhere.
#   godot --headless --path . res://dev/_drop_identity_probe.tscn

var _fails := 0
var _committed_by: CardUI = null


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_fails += 1


func _card(id: String) -> CardUI:
	var inst := CardInstance.from_data(CardData.get_card(id))
	inst.owner = 0
	var ui := CardUI.create(inst, true)
	add_child(ui)
	return ui


func _action_for(ui: CardUI, modal: bool) -> Interaction.Action:
	var act := Interaction.Action.new()
	act.source = ui
	act.modal = modal
	act.is_drag = not modal
	act.role_check = func(_slot: SlotUI) -> int:
		return Interaction.Role.TARGET_VALID    # every slot valid — isolate the identity question
	act.on_commit = func(_slot: SlotUI) -> void:
		_committed_by = ui
	return act


func _ready() -> void:
	await get_tree().process_frame

	var interaction := Interaction.new()
	add_child(interaction)

	var slot := SlotUI.new()
	slot.location = BoardLocation.at(0, 0, 0)
	slot.custom_minimum_size = Vector2(165, 216)
	slot.interaction = interaction
	add_child(slot)

	var card_a := _card("pawn")
	var card_b := _card("pawn")
	await get_tree().process_frame

	# Card A holds a live modal click session. Card B is the one under the cursor.
	interaction.begin(_action_for(card_a, true))
	_check(interaction.modal_active(), "card A holds a modal session")

	# The drop gate is asked with B as the dragged payload.
	_check(not slot._can_drop_data(Vector2.ZERO, card_b),
			"the slot REFUSES a drop of card B while A owns the session")
	interaction.commit_drop(slot, card_b)
	_check(_committed_by == null, "dropping card B commits nothing")
	_check(interaction.active(), "card A's session survives B's stray drop")

	# The owner's own drop still works — the gate must not be a blanket refusal.
	_check(slot._can_drop_data(Vector2.ZERO, card_a), "the slot accepts card A's own drop")
	interaction.commit_drop(slot, card_a)
	_check(_committed_by == card_a, "dropping card A commits card A")

	print("PROBE: %s" % ("OK" if _fails == 0 else "%d FAILED" % _fails))
	get_tree().quit(1 if _fails > 0 else 0)
