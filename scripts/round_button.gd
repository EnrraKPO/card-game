class_name RoundButton
extends Button

# A Button whose HIT AREA is the circle inscribed in its rect, not the rect. For any round widget
# — a disc-backed fab, a medallion, a coin chip — the square hit box is a lie: it claims four
# corners the player can see they aren't pressing, and on a dense screen those corners steal
# clicks from whatever sits behind them. Godot picks a Control by `_has_point`, so overriding it
# is the whole fix; nothing about layout, drawing or focus changes.
#
# Screens that run their own hit-testing against these buttons (a dead-space click handler, say)
# must ask `in_disc` rather than the rect, or the corners become zones where neither the button
# nor the screen responds.


func _has_point(point: Vector2) -> bool:
	return (point - size * 0.5).length() <= minf(size.x, size.y) * 0.5


# The same test in GLOBAL space, for callers doing their own picking against a round widget. Takes
# any Control (the button or a round wrapper around it) so a screen can test the fab it tracks.
static func in_disc(c: Control, global_point: Vector2) -> bool:
	var r := c.get_global_rect()
	return (global_point - r.get_center()).length() <= minf(r.size.x, r.size.y) * 0.5
