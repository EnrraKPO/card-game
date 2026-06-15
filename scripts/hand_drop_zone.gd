class_name HandDropZone
extends PanelContainer

signal card_returned(card_ui: CardUI)


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is CardUI and not (data as CardUI).card_instance.data.is_king


func _drop_data(_at: Vector2, data: Variant) -> void:
	card_returned.emit(data as CardUI)
