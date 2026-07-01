class_name NodeKindForge
extends NodeKind

func enter(_node: MapNodeData, _map_screen: MapScreen) -> void:
	Nav.goto("res://scenes/combination_screen.tscn")
