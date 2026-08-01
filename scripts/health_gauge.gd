class_name HealthGauge
extends Control

# The card's LIFE gauge: the badge says what a unit has left, this says what it has LOST. A number
# alone can't answer "is this thing nearly dead?" without knowing its total, and the total is
# exactly what a board full of strangers doesn't give you — so the missing share is drawn, and the
# maximum is written at the top of the gauge where the scale belongs.
#
# It speaks the mana gauge's language on purpose (see Combat._build_mana_gauge): the same dark
# track and border, the same fill-from-the-bottom stack of chunks, lit for what's there and dim
# for what isn't. One vocabulary for "a pool and how much of it remains", wherever the player
# meets one.
#
# Two regimes, one rule — a chunk per point of max health while the chunks can still be told
# apart, and a single continuous bar once they can't (kings and late-game units run to tens of
# points, and at that size a chunk stack is just a smear with gaps in it). The read is identical
# either way; only the grain changes.
#
# Authored into card_ui.tscn beside the health badge, so it can be dragged like any other card
# component (see the card-scaling note in CardUI) — CardUI.refresh feeds it and hides it for
# spells, and it mirrors with the rest of the stat cluster when the card is flipped.

const MANA_TRACK_BG := Color(0.10, 0.12, 0.20, 0.85)
const MANA_TRACK_BORDER := Color(0.34, 0.38, 0.52)
# Life present / life missing. The dim is a DARK RED, not a neutral grey: what's gone is still
# life, and reading it as empty track would say the unit is smaller than it is.
const LIFE_LIT := Color(0.88, 0.24, 0.30)
const LIFE_DIM := Color(0.30, 0.12, 0.16)

const BORDER := 2.0
const RADIUS := 5
const INSET := 3.0          # track stroke → chunk stack breathing room
const CHUNK_GAP := 1.0
# Below this a chunk stack stops reading as chunks and starts reading as a barcode. In NATIVE
# card units (the card is authored at one size and scaled whole — see CardUI), so the switch
# happens at the same health total on every screen instead of drifting with the card's size.
const MIN_CHUNK := 6.0
const LABEL_H := 24.0       # the max-life cell at the TOP of the gauge
const LABEL_FONT := 19

var _current: int = 0
var _max: int = 0
var _label: Label = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.text = "0"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", LABEL_FONT)
	_label.add_theme_color_override("font_color", Color(0.97, 0.86, 0.88))
	_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_label.offset_bottom = LABEL_H
	add_child(_label)
	_label.text = str(_max)   # honour values set before the node entered the tree


# The one feed, called from CardUI.refresh. Idempotent and cheap — same values in, no redraw.
func set_life(current: int, maximum: int) -> void:
	if current == _current and maximum == _max:
		return
	_current = current
	_max = maximum
	if _label != null:
		_label.text = str(maximum)
	queue_redraw()


# One framed component, cells stacked like the mana gauge's: the max-life number in a header
# cell at the top, a hairline, then the chunk stack filling the rest. The frame runs behind the
# number too — it sits over card art, and a bare glyph there would be unreadable on half the deck.
func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var box := StyleBoxFlat.new()
	box.bg_color = MANA_TRACK_BG
	box.set_corner_radius_all(RADIUS)
	box.set_border_width_all(int(BORDER))
	box.border_color = MANA_TRACK_BORDER
	draw_style_box(box, Rect2(Vector2.ZERO, size))
	draw_rect(Rect2(BORDER, LABEL_H, size.x - BORDER * 2.0, 2.0), MANA_TRACK_BORDER)

	var track := Rect2(0.0, LABEL_H + 2.0, size.x, maxf(0.0, size.y - LABEL_H - 2.0))
	var inner := track.grow(-(BORDER + INSET))
	if inner.size.y <= 0.0 or inner.size.x <= 0.0 or _max <= 0:
		return
	var have := clampi(_current, 0, _max)
	if inner.size.y / float(_max) >= MIN_CHUNK:
		_draw_chunks(inner, have)
	else:
		_draw_bar(inner, have)


# A chunk per point of health, stacked from the BOTTOM like the mana gauge's — the lowest `have`
# chunks lit, the rest dim.
func _draw_chunks(inner: Rect2, have: int) -> void:
	var pitch := inner.size.y / float(_max)
	var h := maxf(1.0, pitch - CHUNK_GAP)
	for i in _max:
		var top := inner.end.y - pitch * float(i + 1)
		draw_rect(Rect2(inner.position.x, top, inner.size.x, h),
				LIFE_LIT if i < have else LIFE_DIM)


# Too many points to tell apart: one solid column, lit from the bottom by the surviving share.
func _draw_bar(inner: Rect2, have: int) -> void:
	draw_rect(inner, LIFE_DIM)
	var lit_h := inner.size.y * (float(have) / float(_max))
	if lit_h > 0.0:
		draw_rect(Rect2(inner.position.x, inner.end.y - lit_h, inner.size.x, lit_h), LIFE_LIT)
