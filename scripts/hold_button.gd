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
# frame anyway (the consumable chip's usability read) overrides _process, sets `always_process`,
# and forwards to _hold_tick. That flag is not a nicety: without it the base's own cancel path
# (reset) switches processing off under a subclass whose poll LIVES there, and the poll never
# runs again — see always_process.
#
# TOUCH: the "still on the button?" test is NOT is_hovered() — hover is a mouse-motion notion and
# a finger that taps without ever moving leaves a Control un-hovered, which cancelled every hold
# on the first frame. Instead the button TRACKS THE POINTER itself (see _track_pointer): touch,
# drag and mouse events all report a local position, and inside-the-rect is measured from that.
# Set hold_pop_scale above 1.0 and the button swells while a hold is in flight — under a fingertip
# the fill is otherwise invisible, so the control gets out from under the finger and reads.

signal commit_requested

const POP_SEC := 0.12       # swell/settle time for the hold pop
const POP_Z_LIFT := 50      # while popped the button draws over its neighbours

# How big the button grows while a hold runs (1.0 = no pop). Set by the subclass before/at _ready.
var hold_pop_scale := 1.0

# Whether this button must keep processing even with no hold in flight — set by a subclass that
# drives its own per-frame poll from _process (the consumable chip's usability read). The base
# stops processing whenever a hold ends, and for such a subclass that is a ONE-WAY DOOR: the
# poll that would notice the button becoming usable again is itself the thing that got switched
# off. The consumable chip lost its hold the moment the placement turn ended (locking cancels an
# in-flight hold, and cancelling calls reset), and stayed dimmed and inert for the rest of the
# fight — usable by every rule, dead to the touch.
var always_process := false

var _holding := false
var _progress := 0.0
var _hold_seconds := 1.0
var _hold_fill_style: StyleBoxFlat = null
var _pointer_local := Vector2.ZERO
var _has_pointer := false
var _popped := false
var _pop_tween: Tween
var _base_z := 0


func _ready() -> void:
	button_down.connect(_on_hold_down)
	button_up.connect(_on_hold_up)
	# The SIGNAL, not the _gui_input override — overriding the virtual would replace BaseButton's
	# own press handling. The signal fires first, so the pointer is current by button_down.
	gui_input.connect(_track_pointer)
	_base_z = z_index
	set_process(always_process)


# Every pointer device, one position: emulated-mouse events (what touch becomes by default),
# real mouse motion, and the raw screen touch/drag events that also reach a Control.
func _track_pointer(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	if touch != null:
		_pointer_local = touch.position
		_has_pointer = true
		return
	var drag := event as InputEventScreenDrag
	if drag != null:
		_pointer_local = drag.position
		_has_pointer = true
		return
	var mouse := event as InputEventMouse
	if mouse != null:
		_pointer_local = mouse.position
		_has_pointer = true


# Is the pointer still over the button? Falls back to hover only before any pointer event has
# ever landed (keyboard/programmatic presses).
func _pointer_inside() -> bool:
	if _has_pointer:
		return Rect2(Vector2.ZERO, size).has_point(_pointer_local)
	return is_hovered()


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
	_set_popped(true)
	queue_redraw()


func _on_hold_down() -> void:
	_hold_pressed()


func _on_hold_up() -> void:
	if _holding:
		reset()


func _process(delta: float) -> void:
	if not _holding:
		set_process(always_process)
		return
	_hold_tick(delta)


# One frame of an armed hold: slide-off cancels, a full fill commits. Kept separate from
# _process so an always-processing subclass can drive it from its own loop.
func _hold_tick(delta: float) -> void:
	if not _holding:
		return
	# Sliding off the button mid-hold is a back-out, same as releasing early.
	if not _pointer_inside():
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
	set_process(always_process)   # never below what the subclass's own poll needs
	_set_popped(false)
	queue_redraw()


func is_holding() -> bool:
	return _holding


# The hold pop: grow in place around the button's centre while the hold runs, lifted over its
# neighbours, and settle back on commit or cancel. No-op unless the subclass opted in.
func _set_popped(on: bool) -> void:
	if hold_pop_scale <= 1.0 or on == _popped:
		return
	_popped = on
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()
	pivot_offset = size * 0.5
	if on:
		z_index = _base_z + POP_Z_LIFT
	_pop_tween = create_tween()
	_pop_tween.tween_property(self, "scale",
		Vector2.ONE * hold_pop_scale if on else Vector2.ONE, POP_SEC) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if not on:
		_pop_tween.tween_callback(func() -> void: z_index = _base_z)


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
