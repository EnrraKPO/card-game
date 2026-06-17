class_name NodeKindEvent
extends NodeKind

func enter(node: MapNodeData, map_screen: MapScreen) -> void:
	# Hand the node's pre-rolled stat to the screen (transient — not saved).
	GameData.current_event_attr = node.event_attr
	map_screen.get_tree().change_scene_to_file("res://scenes/event_screen.tscn")
