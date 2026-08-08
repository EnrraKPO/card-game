class_name SpeechBubble
extends Control

# A dialog bubble a card (or any Control) speaks through — the surrender line's home, and
# THE component for any future "a unit says something" moment: one bubble idiom, never
# hand-rolled per feature. It ARRIVES (pops from its speaker with a little overshoot,
# per the arrival language) and leaves by drifting up as it fades.
#
# Mounted on its own high CanvasLayer: card views and slot cues ride overlay layers of
# their own, and a bubble must float above whatever its speaker is doing (the overlay
# furniture rule). The whole thing is mouse-transparent — a speech bubble is scenery,
# it must never eat a click.

const LAYER := 230
const TAIL_H := 14.0
const BG := Color(0.97, 0.95, 0.88)
const BORDER := Color(0.16, 0.13, 0.10)
const INK := Color(0.14, 0.11, 0.09)

var _panel: PanelContainer
var _tail_x := 0.0


# Says `text` above `anchor`, holding it readable for `hold` seconds; awaitable end to
# end (arrival → hold → departure), and cleans its own layer up afterwards.
static func say(anchor: Control, text: String, hold: float = 1.6) -> void:
	var layer := CanvasLayer.new()
	layer.layer = LAYER
	anchor.get_viewport().add_child(layer)
	var b := SpeechBubble.new()
	b._build(text)
	layer.add_child(b)
	# The panel only knows its size after a layout pass — place a frame late, then show
	# (placing on arrival-frame coordinates is the classic one-frame-wrong landmine).
	await b.get_tree().process_frame
	b._place_over(anchor)
	await b._play(hold)
	layer.queue_free()


func _build(text: String) -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	modulate.a = 0.0
	_panel = PanelContainer.new()
	_panel.mouse_filter = MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = BG
	box.border_color = BORDER
	box.set_border_width_all(2)
	box.set_corner_radius_all(12)
	box.content_margin_left = 16.0
	box.content_margin_right = 16.0
	box.content_margin_top = 9.0
	box.content_margin_bottom = 9.0
	_panel.add_theme_stylebox_override("panel", box)
	var l := Label.new()
	l.mouse_filter = MOUSE_FILTER_IGNORE
	l.text = text
	l.add_theme_font_size_override("font_size", 21)
	l.add_theme_color_override("font_color", INK)
	_panel.add_child(l)
	add_child(_panel)


# Bubble bottom-center (tail tip) sits on the speaker's top edge; clamped so a speaker at
# the screen's rim never pushes the words out of view. Coordinates go through the canvas
# transform — the fresh CanvasLayer is identity, the speaker's layer may not be.
func _place_over(anchor: Control) -> void:
	var xf := anchor.get_global_transform_with_canvas()
	var top_center := xf * Vector2(anchor.size.x / 2.0, 0.0)
	var sz := _panel.size
	var vp := get_viewport_rect().size
	var x := clampf(top_center.x - sz.x / 2.0, 8.0, maxf(8.0, vp.x - sz.x - 8.0))
	var y := clampf(top_center.y - sz.y - TAIL_H - 4.0, 8.0, maxf(8.0, vp.y - sz.y))
	_panel.position = Vector2(x, y)
	_tail_x = clampf(top_center.x, x + 22.0, x + sz.x - 22.0)
	pivot_offset = Vector2(_tail_x, y + sz.y + TAIL_H)
	queue_redraw()


func _draw() -> void:
	if _panel == null:
		return
	var bottom := _panel.position.y + _panel.size.y - 1.0
	var tip := Vector2(_tail_x, bottom + TAIL_H)
	draw_colored_polygon(PackedVector2Array([
			Vector2(_tail_x - 10.0, bottom), Vector2(_tail_x + 10.0, bottom), tip]), BG)
	draw_line(Vector2(_tail_x - 10.0, bottom + 1.0), tip, BORDER, 2.0)
	draw_line(Vector2(_tail_x + 10.0, bottom + 1.0), tip, BORDER, 2.0)


func _play(hold: float) -> void:
	scale = Vector2(0.6, 0.6)
	var arrive := create_tween()
	arrive.set_parallel(true)
	arrive.tween_property(self, "modulate:a", 1.0, 0.16)
	arrive.tween_property(self, "scale", Vector2.ONE, 0.28) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await arrive.finished
	await get_tree().create_timer(hold).timeout
	var leave := create_tween()
	leave.set_parallel(true)
	leave.tween_property(self, "modulate:a", 0.0, 0.28)
	leave.tween_property(self, "position:y", position.y - 14.0, 0.28)
	await leave.finished
