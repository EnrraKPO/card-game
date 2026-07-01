class_name NodeKindShop
extends NodeKind

func enter(_node: MapNodeData, _map_screen: MapScreen) -> void:
	Nav.goto("res://scenes/shop_screen.tscn")
