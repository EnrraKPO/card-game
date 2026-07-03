class_name MapCanvas
extends Control

# The scrollable content of the map screen: it holds the node medallions (added by MapScreen)
# and draws the trails between connected nodes in its own coordinate space, so the nodes,
# labels and trails all scroll together inside the ScrollContainer.
#
# Trails are drawn as a slightly-curved line of breadcrumb dots rather than a hard line —
# softer and less busy than the old straight grey lines, and the gentle bow keeps parallel
# routes from looking like a ruler grid.

var positions: Dictionary = {}   # node id -> Vector2 in canvas space
var map_data: MapData
var node_radius: float = 30.0     # so dots can start clear of the node art
var current_id: int = -1          # the node the player stands on, or -1 on a fresh map
var reachable_ids: Array = []     # ids the player may move to from current_id
# Trail look — set by MapScreen from its Inspector-tunable exports.
var curve_bow: float = 0.18       # sideways bow of the trail (0 = straight)
var curve_dir: float = -1.0       # +1 / -1: which side the trail bows (set by MapScreen)
var dot_radius_mult: float = 0.085  # dot radius ×node_radius
var dot_spacing_mult: float = 0.5   # gap between dots ×node_radius

var _dragging := false


func _ready() -> void:
	# Hand cursor over the open map area hints it's draggable, without needing an instruction label.
	mouse_default_cursor_shape = Control.CURSOR_DRAG


# Click-and-hold-drag panning: a node Button on top of us (mouse_filter STOP) still eats its own
# clicks first, so this only fires over open canvas — exactly where there's nothing to click
# anyway. Godot implicitly keeps routing motion/release to us once we've captured the press, even
# if the pointer drifts over a button mid-drag, so panning stays smooth across the whole canvas.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var scroll := get_parent() as ScrollContainer
		if scroll:
			scroll.scroll_horizontal -= int(event.relative.x)
			scroll.scroll_vertical -= int(event.relative.y)
		accept_event()


func _draw() -> void:
	if positions.is_empty() or map_data == null:
		return
	# Muted-but-solid slate for routes not taken, warm gold along the travelled path, bright
	# gold for the edges leaving the current node — the immediate branch choices.
	var dim := Color(0.33, 0.34, 0.45, 0.8)
	var taken := Color(0.88, 0.72, 0.32, 0.95)
	var choice := Color(1.0, 0.85, 0.30, 1.0)
	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			var from: Vector2 = positions.get(node.id, Vector2.ZERO)
			for next_id: int in node.connections:
				var to: Vector2 = positions.get(next_id, Vector2.ZERO)
				var col := dim
				var emphasis := 1.0
				if node.id == current_id and next_id in reachable_ids:
					col = choice
					emphasis = 1.6
				elif node.visited:
					col = taken
					emphasis = 1.2
				_draw_trail(from, to, col, emphasis)


# A row of dots along a quadratic curve from `from` to `to`, skipping the ends so the dots
# clear both node circles.
func _draw_trail(from: Vector2, to: Vector2, color: Color, emphasis: float) -> void:
	var seg := to - from
	var length := seg.length()
	if length < 1.0:
		return
	# Bow scales with the edge's HORIZONTAL travel (seg.x, signed), so a straight-up edge stays
	# straight and only angled edges curve — more the more they lean. Offset is perpendicular
	# to the edge; the signed seg.x sets both magnitude and which side it bows.
	var perp := Vector2(-seg.y, seg.x).normalized()
	var ctrl := (from + to) * 0.5 + perp * (curve_bow * seg.x * curve_dir)

	var dot_r := maxf(2.0, node_radius * dot_radius_mult) * emphasis
	var spacing := maxf(9.0, node_radius * dot_spacing_mult)
	# Trim both ends past the node radius (plus a little) so dots don't tuck under the icons.
	var margin := clampf((node_radius + dot_r * 2.0) / length, 0.06, 0.42)
	var step := spacing / length
	var shadow := Color(0.06, 0.06, 0.12, 0.35)
	var t := margin
	while t <= 1.0 - margin + 0.0001:
		var p := _bezier(from, ctrl, to, t)
		# Soft dark under-dot: keeps the breadcrumbs legible against light background art.
		draw_circle(p, dot_r * 1.5, shadow, true, -1.0, true)
		draw_circle(p, dot_r, color, true, -1.0, true)
		t += step


func _bezier(p0: Vector2, c: Vector2, p1: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return u * u * p0 + 2.0 * u * t * c + t * t * p1
