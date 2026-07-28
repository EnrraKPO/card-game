class_name HoldButton
extends BaseButton

# The shared hold-to-confirm state machine: a press must be HELD for a duration to commit —
# the frame fills bottom-up like a gauge, and releasing (or sliding off) before it completes
# cancels cleanly. Extracted from MoveButton so every "deliberate press" control (the move
# button, a consumable relic's chip) runs ONE mechanism: same cancel rules, same fill read,
# one behaviour on every input device (touch presses arrive as emulated mouse and ride the
# same path).
#
# Extends BaseButton (not a styled Button) deliberately: it draws no theme chrome of its own
# (subclasses own their entire presentation), and Combat._click_engages recognises BaseButton —
# so backing out of a hold never reads as a "click on nothing".
#
# Subclass contract:
#   _hold_pressed()  — what a press does. Default arms the hold; override to gate it (the move
#                      button commits immediately while its safety toggle is off; a consumable
#                      chip ignores presses while it isn't usable).
#   _hold_duration() — seconds a hold takes to fill, read once when the hold arms.
#   _draw_hold_fill(...) — the bottom-up progress gauge, for the subclass's _draw to place
#                      inside its own frame.
# The base owns _process while idle (off) and holding (on); a subclass that needs to poll every
# frame anyway (the consumable chip's usability read) overrides _process, keeps processing on,
# and forwards to _hold_tick.

signal commit_requested

var _holding := false
var _progress := 0.0
var _hold_seconds := 1.0
var _hold_fill_style: StyleBoxFlat = null


func _ready() -> void:
	button_down.connect(_on_hold_down)
	button_up.connect(_on_hold_up)
	set_process(false)


# Seconds the hold takes to fill. Read at arm time (begin_hold), so a mid-hold registry change
# never yanks a fill already in motion.
func _hold_duration() -> float:
	return 1.0


# What a press does — the subclass's gate. The default is the plain behaviour: every press
# arms the hold.
func _hold_pressed() -> void:
	begin_hold()


func begin_hold() -> void:
	_holding = true
	_progress = 0.0
	_hold_seconds = maxf(0.05, _hold_duration())
	set_process(true)
	queue_redraw()


func _on_hold_down() -> void:
	_hold_pressed()


func _on_hold_up() -> void:
	if _holding:
		reset()


func _process(delta: float) -> void:
	if not _holding:
		set_process(false)
		return
	_hold_tick(delta)


# One frame of an armed hold: slide-off cancels, a full fill commits. Kept separate from
# _process so an always-processing subclass can drive it from its own loop.
func _hold_tick(delta: float) -> void:
	if not _holding:
		return
	# Sliding off the button mid-hold is a back-out, same as releasing early.
	if not is_hovered():
		reset()
		return
	_progress = minf(1.0, _progress + delta / _hold_seconds)
	queue_redraw()
	if _progress >= 1.0:
		reset()
		commit_requested.emit()


# Cancels any in-flight hold and clears the fill — also the teardown path when the owner hides
# the button mid-gesture (action ended under it: right-click cancel, phase change).
func reset() -> void:
	_holding = false
	_progress = 0.0
	set_process(false)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		reset()


# The progress gauge: a rounded rect filling bottom-up inside the button, inset so it lives
# inside the subclass's frame stroke. Call from the subclass's _draw.
func _draw_hold_fill(color: Color, inset_x: float, inset_y: float, radius_frac: float) -> void:
	if _progress <= 0.0:
		return
	if _hold_fill_style == null:
		_hold_fill_style = StyleBoxFlat.new()
	_hold_fill_style.bg_color = color
	var ix := size.x * inset_x
	var iy := size.y * inset_y
	var inner := Rect2(ix, iy, size.x - ix * 2.0, size.y - iy * 2.0)
	var h := inner.size.y * clampf(_progress, 0.0, 1.0)
	_hold_fill_style.set_corner_radius_all(int(size.x * radius_frac))
	draw_style_box(_hold_fill_style, Rect2(inner.position.x, inner.end.y - h, inner.size.x, h))
