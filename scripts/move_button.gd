class_name MoveButton
extends HoldButton

# The explicit "move here" control a static unit selection shows on each eligible empty slot —
# the deliberate replacement for the old click-anywhere-to-move (retired for causing accidental
# moves). Pressing it commits the move; pressing the slot anywhere else keeps its current
# meaning (clears the selection).
#
# SELF-CONTAINED: the button owns its entire presentation as its own children — the open-rect
# frame (the same glyph the empty-slot marker wears, at the marker's exact half-slot box), the
# spotlight pool + arrow scaled to sit inside it, and the hold-progress fill. It borrows no
# the demoted board UI's cue nodes, and it lives at ONE fixed z for its whole life: above the card badge/tag
# layer (CardUI.TAG_Z) — by definition this is a control that must stay readable over any card
# content its slot can show (the ghost phantom mounts under it while hovered/held).
#
# ALL hover feedback belongs to the button, not the slot: hovering it wakes the bobbing arrow
# and reports hover out (hover_changed) so the board can mount the landing phantom and declare
# the targeting preview from this spot. The rest of the slot is non-interactive dead space.
#
# Safety hold (UxPrefs.move_hold_enabled, the settings toggle): while ON, the press must be
# HELD for ux.move_hold.duration seconds — the shared HoldButton machinery (see there for the
# cancel rules and why it extends BaseButton). The landing preview is on screen for the whole
# hold: the fill IS the window to read it and back out. While OFF, the press commits
# immediately.

signal hover_changed(on: bool)

# Above CardUI.TAG_Z (60, the stat-badge layer): the one static home for a slot control that
# must read over any card content beneath it. Set once, never changed at runtime.
const BUTTON_Z := 65
# The resting button rides the same softening as the rest of the move cue; hover lifts it to
# full strength (the same "you are pointing at it" step the arrow's appearance makes).
const IDLE_ALPHA := 0.85
const FILL_COLOR := Color(1.0, 0.9, 0.55, 0.32)   # warm translucent gold — the confirm accent
# The frame texture (the "open" glyph) draws its rounded rect INSET from the texture bounds
# (slot_open.svg: line at ~6.6%/5% with a thick stroke) — the fill must live inside the
# stroke's inner edge or it reads as spilling out of the button.
const FILL_INSET_X := 0.10
const FILL_INSET_Y := 0.08
const FILL_RADIUS_FRAC := 0.08   # fill corner radius as a fraction of the button width
# The spot+arrow composition, laid out relative to the CONTENT box (the frame's inside):
# the same spotlight-pool-with-arrow-above read as the drag cue, scaled to fit the frame.
const CONTENT_INSET_X := 0.10    # content box inset from the button bounds (clears the stroke)
const CONTENT_INSET_Y := 0.10
const SPOT_W := 0.95             # pool width as a fraction of the content box width — the pool
                                 # spans nearly the full frame so the icon stays READABLE at
                                 # slot size (the frame is what constrains it, nothing else)
const SPOT_ASPECT := 0.30        # pool height / width — strong perspective foreshorten
const ARROW_W := 0.70            # arrowhead box side as a fraction of the pool width — lands at
                                 # roughly the drag cue's absolute arrow size inside this frame
const ARROW_GAP := 0.30          # gap between arrowhead base and pool, of the pool height
const DOWN_BIAS := 0.03          # nudge the composition down so the pool hugs the lower half
const BOB_SEC := 0.65            # one leg of the arrow's bob loop (matches the drag cue)

var _frame: TextureRect
var _spot: TextureRect
var _arrow: TextureRect
var _arrow_tween: Tween
var _arrow_top_y := 0.0
var _arrow_bottom_y := 0.0
var _hover := false


func _ready() -> void:
	super._ready()
	focus_mode = Control.FOCUS_NONE
	z_index = BUTTON_Z
	modulate = Color(1.0, 1.0, 1.0, IDLE_ALPHA)

	_frame = _make_icon("open")
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_spot = _make_icon("move_ring")
	_spot.stretch_mode = TextureRect.STRETCH_SCALE
	_arrow = _make_icon("move_arrow")
	_arrow.visible = false   # the arrow belongs to MOTION — it wakes on hover

	mouse_entered.connect(func() -> void: _set_hover(true))
	mouse_exited.connect(func() -> void: _set_hover(false))
	_layout()


func _make_icon(glyph: String) -> TextureRect:
	var icon := TextureRect.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = BoardGlyphs.tex(glyph)
	add_child(icon)
	return icon


# Sizes the pool + arrow inside the frame from the button's current size; keeps the arrow's
# bob endpoints current (same technique as the slot's drag cue).
func _layout() -> void:
	if _spot == null:
		return
	var ix := size.x * CONTENT_INSET_X
	var iy := size.y * CONTENT_INSET_Y
	var inner := Rect2(ix, iy, size.x - ix * 2.0, size.y - iy * 2.0)
	var w := inner.size.x * SPOT_W
	var h := w * SPOT_ASPECT
	var arrow_side := w * ARROW_W
	var gap := h * ARROW_GAP
	var total := arrow_side + gap + h
	var top := inner.position.y + (inner.size.y - total) * 0.5 + size.y * DOWN_BIAS
	var spot_top := top + arrow_side + gap
	_spot.size = Vector2(w, h)
	_spot.position = Vector2(inner.position.x + (inner.size.x - w) * 0.5, spot_top)
	_arrow.size = Vector2(arrow_side, arrow_side)
	_arrow.position.x = inner.position.x + (inner.size.x - arrow_side) * 0.5
	_arrow_top_y = spot_top - arrow_side
	_arrow_bottom_y = _arrow_top_y + arrow_side * 0.28
	if _arrow_tween != null and _arrow_tween.is_valid():
		_restart_arrow_bob()   # endpoints moved — rebuild the loop around them
	else:
		_arrow.position.y = _arrow_top_y


func _set_hover(on: bool) -> void:
	if on == _hover:
		return
	_hover = on
	modulate = Color.WHITE if on else Color(1.0, 1.0, 1.0, IDLE_ALPHA)
	_arrow.visible = on
	if on:
		_restart_arrow_bob()
	else:
		_stop_arrow_bob()
		_arrow.position.y = _arrow_top_y
	hover_changed.emit(on)


func _restart_arrow_bob() -> void:
	_stop_arrow_bob()
	_arrow.position.y = _arrow_top_y
	_arrow_tween = create_tween().set_loops()
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_bottom_y, BOB_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_top_y, BOB_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_arrow_bob() -> void:
	if _arrow_tween != null and _arrow_tween.is_valid():
		_arrow_tween.kill()
	_arrow_tween = null


func _hold_pressed() -> void:
	if not UxPrefs.move_hold_enabled:
		commit_requested.emit()
		return
	begin_hold()


func _hold_duration() -> float:
	return GameData.value_f("ux.move_hold.duration")


func _notification(what: int) -> void:
	super._notification(what)   # the base cancels an in-flight hold when hidden mid-gesture
	match what:
		NOTIFICATION_RESIZED:
			_layout()
		NOTIFICATION_VISIBILITY_CHANGED:
			if not visible:
				# A button hidden mid-hover never gets its mouse_exited — report the hover
				# ending so whatever the hover raised (phantom, preview) is released.
				_set_hover(false)


func _draw() -> void:
	_draw_hold_fill(FILL_COLOR, FILL_INSET_X, FILL_INSET_Y, FILL_RADIUS_FRAC)
