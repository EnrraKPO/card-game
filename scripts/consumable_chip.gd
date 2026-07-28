class_name ConsumableChip
extends HoldButton

# The relic-tray chip a CONSUMABLE relic wears (see RelicData.consumable): unlike the passive
# chips, this one is a control the player OPERATES, so it dresses as a button — a raised framed
# plate around the relic's art (or letter) that says "press me" where the passive chips say
# "read me". Using it is deliberate by construction: the press must be HELD (the shared
# HoldButton safety mechanism — ux.consume_hold.duration) while the frame fills bottom-up;
# a full fill emits commit_requested and the tray's owner spends the relic. Unlike the move
# button there is no immediate-commit preference: a consumable is gone when it fires, so the
# hold is the interaction, not a toggleable guard.
#
# Three lives, derived by self-poll (the pull-presentation idiom — nobody pushes state at it):
#   display — no `check` installed (map HUD): full colour, inert hold; a tap opens the
#             inspector like any chip, and the description says where it can be used.
#   ready   — `check` says the player may act now (combat, placement turn): lit frame, live hold.
#   locked  — `check` says not now (resolution running): dimmed, presses ignored.
# A tap short of a full hold opens the inspector in every state — the touch reading path —
# except immediately after a commit, so the spend never trails a stray overlay.

signal inspect_requested

const FILL_COLOR := Color(1.0, 0.9, 0.55, 0.38)   # the confirm accent MoveButton's fill wears
const FILL_INSET := 0.06
const FILL_RADIUS_FRAC := 0.12
const ART_PAD := 5.0            # frame stroke + breathing room around the art
const LOCKED_ALPHA := 0.45
const FRAME_BG := Color(0.13, 0.15, 0.22)
const FRAME_BORDER := Color(0.85, 0.72, 0.40)      # warm gold — the "operable" accent
const FRAME_BORDER_LOCKED := Color(0.38, 0.38, 0.46)

var relic: RelicData            # set before entering the tree, like the tray's own flags
var check: Callable = Callable()   # "may the player use a consumable right now" — combat
									# installs one; invalid = display mode (map HUD)

var _frame_style: StyleBoxFlat
var _ready_now := false
var _just_committed := false


func _ready() -> void:
	super._ready()
	focus_mode = Control.FOCUS_NONE

	_frame_style = StyleBoxFlat.new()
	_frame_style.bg_color = FRAME_BG
	_frame_style.set_corner_radius_all(9)
	_frame_style.set_border_width_all(2)

	if relic != null and relic.icon != null:
		var tex := TextureRect.new()
		tex.texture = relic.icon
		tex.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex.offset_left = ART_PAD
		tex.offset_top = ART_PAD
		tex.offset_right = -ART_PAD
		tex.offset_bottom = -ART_PAD
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(tex)
	elif relic != null:
		var lbl := Label.new()
		lbl.text = relic.letter
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", relic.color.lightened(0.35))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(lbl)

	pressed.connect(_on_pressed)
	commit_requested.connect(func() -> void: _just_committed = true)
	# Always processing: the chip POLLS its usability every frame (nothing pushes phase changes
	# at the tray) and forwards the tick to the hold machinery.
	_poll()
	set_process(true)


func _process(delta: float) -> void:
	_poll()
	_hold_tick(delta)


func _poll() -> void:
	var on := not check.is_valid() or bool(check.call())
	if on != _ready_now:
		_ready_now = on
		if not on:
			reset()   # locking mid-hold cancels the hold, same as sliding off
		queue_redraw()
	# Applied unconditionally (not only on flips) so the very first poll dresses the initial
	# state too — same value re-assignments are free.
	modulate = Color.WHITE if on else Color(1.0, 1.0, 1.0, LOCKED_ALPHA)


func _hold_pressed() -> void:
	# Armed only where a live check allows it — in display mode (no check) the hold stays
	# inert and the press falls through to the inspector tap.
	if check.is_valid() and _ready_now:
		begin_hold()


func _hold_duration() -> float:
	return GameData.value_f("ux.consume_hold.duration")


# The tap-reading path (see RelicTray._make_chip: tap → detail overlay, everywhere). A release
# that just completed the hold is the SPEND, not a read — swallow that one.
func _on_pressed() -> void:
	if _just_committed:
		_just_committed = false
		return
	inspect_requested.emit()


func _draw() -> void:
	var hovered := is_hovered() and _ready_now
	_frame_style.bg_color = FRAME_BG.lightened(0.08) if hovered else FRAME_BG
	_frame_style.border_color = FRAME_BORDER if _ready_now else FRAME_BORDER_LOCKED
	draw_style_box(_frame_style, Rect2(Vector2.ZERO, size))
	_draw_hold_fill(FILL_COLOR, FILL_INSET, FILL_INSET, FILL_RADIUS_FRAC)


func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_MOUSE_ENTER or what == NOTIFICATION_MOUSE_EXIT:
		queue_redraw()
