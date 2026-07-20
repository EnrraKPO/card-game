extends Node

# UI form-factor for the game. Two jobs:
#  1. is_compact() — the flag screens consult to pick a touch/handheld layout variant
#     (fill the screen, large tap targets) instead of the desktop one.
#  2. A modest content_scale_factor bump on mobile, so fixed-size bits (fonts, the combat
#     board) read a little larger. Fill-based compact layouts adapt to this automatically.
#
# Compact is true on real handhelds (OS "mobile" feature) and — for in-editor preview —
# whenever the run window is shrunk narrow. Screens can rebuild on `layout_changed`.

signal layout_changed

# Mobile zoom is DEAD (user directive 2026-07-19): BIG comes from the layouts themselves
# filling the screen, not from magnification. One picture, identical on every device.
const MOBILE_FACTOR := 1.0
# Window narrower than this (px) counts as compact — real for handhelds, and the knob for
# previewing the mobile layout in the editor by shrinking the run window.
const COMPACT_WIDTH := 1100.0

# Safe-area inset: how far interactables must stay clear of the screen edges. The edges are
# where mobile browsers steal touches (back/forward swipe gestures, rounded corners, notches),
# so corner buttons and edge-pinned content read as "hard to press" there. Generous on touch,
# small on desktop (just breathing room). The single source of truth — see ScreenUI and combat.
const SAFE_INSET_COMPACT := 40.0
const SAFE_INSET_DESKTOP := 28.0

var _compact := false
# Latched true by the first real touch event — see is_touch(). Never cleared.
var _touched := false


func is_compact() -> bool:
	return _compact


# Touch devices have no hover: a finger either presses or isn't there. What Godot's
# emulate_mouse_from_touch leaves behind is a ghost cursor parked wherever you last tapped,
# which then trips hover tooltips over whatever sits under it. So NO hover tooltip anywhere on
# touch — card detail is the long-press CardInspector, and the rest were never readable anyway.
#
# Two sources, because the static one can lie: DisplayServer.is_touchscreen_available() is a
# capability probe, and mobile browsers have been known to under-report it. A real
# InputEventScreenTouch is proof, so the first one ever seen latches touch mode for good
# (_input below). The latch can only ever turn touch ON — a stray mouse never turns it off.
func is_touch() -> bool:
	return _touched or DisplayServer.is_touchscreen_available()


# THE tooltip setter for the whole game. Godot only invokes _make_custom_tooltip when
# tooltip_text is non-empty, so clearing the text is what actually disables a tooltip —
# both the rich custom panels and the plain native label. Always assign through here.
func tip(control: Control, text: String) -> void:
	control.tooltip_text = "" if is_touch() else text


# Edge clearance for interactables, in viewport units. Larger on touch (see SAFE_INSET_*).
func safe_inset() -> float:
	return SAFE_INSET_COMPACT if _compact else SAFE_INSET_DESKTOP


func _ready() -> void:
	get_window().size_changed.connect(_apply)
	_apply()


# Watch for the first real touch (see is_touch). Anything already on screen was built while we
# still believed we were on a mouse, so it carries live tooltip_text — sweep it away once. The
# tooltip only fires after a hover delay, and this runs on the very touch that would arm it, so
# the sweep lands first. Everything built afterwards goes through tip() and is born clean.
func _input(event: InputEvent) -> void:
	if _touched or not (event is InputEventScreenTouch):
		return
	_touched = true
	set_process_input(false)   # one-shot: the latch never clears, so stop listening
	_strip_tooltips(get_tree().root)


func _strip_tooltips(node: Node) -> void:
	var control := node as Control
	if control != null:
		control.tooltip_text = ""
	for child in node.get_children():
		_strip_tooltips(child)


func _apply() -> void:
	var win := get_window()
	var compact := OS.has_feature("mobile") or win.size.x < COMPACT_WIDTH
	var factor := MOBILE_FACTOR if compact else 1.0
	# Only touch the viewport when something actually changes — the Android soft keyboard
	# fires size_changed while you type, and re-applying content_scale_factor mid-entry
	# disrupts the IME (drops focus / dismisses the keyboard).
	if not is_equal_approx(win.content_scale_factor, factor):
		win.content_scale_factor = factor
	if compact != _compact:
		_compact = compact
		layout_changed.emit()
