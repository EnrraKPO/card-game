class_name NodeKind
extends RefCounted

# Called when the player selects a node of this kind on the map.
# Default: no-op — used for node types without dedicated gameplay yet
# (Event, Shop, Rest today; the map already advances past them on selection
# regardless of this method). Override in a subclass to give a node type
# real behaviour, then register an instance in MapScreen._node_kinds.
func enter(_node: MapNodeData, _map_screen: MapScreen) -> void:
	pass
