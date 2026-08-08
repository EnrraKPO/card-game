class_name HandDropZone
extends PanelContainer

signal card_returned(card_ui: CardUI)


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if not (data is CardUI):
		return false
	var inst := (data as CardUI).card_instance
	if inst.data.is_king:
		return false
	# Buildings are rooted once fielded — an armed building's drag exists only to cast its
	# ability, never to come back to hand.
	if CombatContext.fielded(inst) and inst.data.is_building():
		return false
	DragGhost.report(DragGhost.State.UNIT, self)   # returning to hand is a move — ghost shows the unit
	return true


func _drop_data(_at: Vector2, data: Variant) -> void:
	card_returned.emit(data as CardUI)
