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

# Mobile zoom for fixed-size content — mainly the combat board, which has no compact
# layout of its own (it just scales). Menus use fill-based compact layouts that adapt to
# any factor, so this only really affects gameplay.
const MOBILE_FACTOR := 1.35
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


func is_compact() -> bool:
	return _compact


# Edge clearance for interactables, in viewport units. Larger on touch (see SAFE_INSET_*).
func safe_inset() -> float:
	return SAFE_INSET_COMPACT if _compact else SAFE_INSET_DESKTOP


func _ready() -> void:
	get_window().size_changed.connect(_apply)
	_apply()


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
