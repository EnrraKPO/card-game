class_name NodeKindForge
extends NodeKind

func enter(_node: MapNodeData, map_screen: MapScreen) -> void:
	map_screen.get_tree().change_scene_to_file("res://scenes/combination_screen.tscn")
