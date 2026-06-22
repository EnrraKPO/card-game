class_name NodeKindEvent
extends NodeKind

func enter(node: MapNodeData, map_screen: MapScreen) -> void:
	# A "?" site runs one of two events, decided at map generation (node.event_kind).
	if node.event_kind == "relic":
		map_screen.get_tree().change_scene_to_file("res://scenes/relic_event_screen.tscn")
		return
	# Hand the node's pre-rolled stat to the trainer screen (transient — not saved).
	GameData.current_event_attr = node.event_attr
	map_screen.get_tree().change_scene_to_file("res://scenes/event_screen.tscn")
