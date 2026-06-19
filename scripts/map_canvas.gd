class_name MapCanvas
extends Control

# The scrollable content of the map screen: it holds the node buttons (added by MapScreen)
# and draws the connection lines between nodes in its own coordinate space, so the nodes,
# labels and lines all scroll together inside the ScrollContainer.

var positions: Dictionary = {}   # node id -> Vector2 in canvas space
var map_data: MapData
var line_width: float = 2.0


func _draw() -> void:
	if positions.is_empty() or map_data == null:
		return
	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			var from: Vector2 = positions.get(node.id, Vector2.ZERO)
			for next_id: int in node.connections:
				var to: Vector2 = positions.get(next_id, Vector2.ZERO)
				var col: Color = Color(0.7, 0.6, 0.25, 0.8) if node.visited \
					else Color(0.55, 0.55, 0.55, 0.4)
				draw_line(from, to, col, line_width)
