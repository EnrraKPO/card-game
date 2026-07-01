class_name NodeKindRest
extends NodeKind

func enter(_node: MapNodeData, _map_screen: MapScreen) -> void:
	Nav.goto("res://scenes/rest_screen.tscn")
