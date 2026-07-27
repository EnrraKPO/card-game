class_name GoldBag
extends VBoxContainer

# The run purse, given a BODY on the combat screen: the bag every coin a kill pays flies into
# (see CoinFlightFx). It wears a relic chip's presentation — art filling a square, frameless,
# tooltip on hover — and stands at the TOP of the relic strip, above the count and the chips,
# because it is the same kind of thing: a run-long possession combat only reports on.
#
# THE ONE RULE HERE: the number on the bag is not the purse, it is what the player has SEEN
# arrive. Gold is banked the instant a unit dies (GameData.kill_bounty → RunData.gold), but the
# coins take a moment to fly, and a counter that jumped to the total before the first coin
# landed would make the flight decorative. So the widget shows its own `_shown` tally, and the
# arriving coins are what move it:
#
#   bag.expect_coins(n)   # n coins are on their way — stop mirroring the purse
#   bag.land_coin()       # one arrived: +1, and a pop
#
# When the last expected coin lands the tally snaps to the true purse, so any gold that changed
# hands by some other route (a relic, a debug grant) is reconciled and the two can't drift.
# With nothing in flight the bag simply mirrors RunData through GameSignals.gold_changed.

const ART := "res://assets/ui/gold_bag.png"

# Matched to RelicTray's vertical chips, so bag and relics read as one column of equals.
const CHIP := 64
const CHIP_COMPACT := 76

var _icon: TextureRect
var _count: Label
var _shown: int = 0
var _pending: int = 0   # coins still in flight (see the header)


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	mouse_filter = Control.MOUSE_FILTER_PASS   # its own tooltip, without eating strip input

	var s: int = CHIP_COMPACT if UIScale.is_compact() else CHIP
	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(s, s)
	_icon.size_flags_horizontal = SIZE_SHRINK_CENTER
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(ART):
		_icon.texture = load(ART)
	add_child(_icon)

	_count = Label.new()
	_count.add_theme_font_size_override("font_size", 22 if UIScale.is_compact() else 18)
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count.add_theme_color_override("font_color", Color(1.0, 0.86, 0.45))   # gold, on the strip's
	_count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))   # dark track panel
	_count.add_theme_constant_override("outline_size", 4)
	add_child(_count)

	_shown = _purse()
	_refresh_label()
	GameSignals.gold_changed.connect(_on_gold_changed)


# Where a coin should aim for — the centre of the bag's art, in global coordinates.
func drop_point() -> Vector2:
	return _icon.get_global_rect().get_center() if _icon != null else get_global_rect().get_center()


# Declares `n` coins in flight: until they land, the tally follows THEM, not the purse.
func expect_coins(n: int) -> void:
	_pending = maxi(0, _pending + n)


# One coin arrived. The tally climbs by exactly one and the bag takes the weight of it; the
# last coin of a flight reconciles against the real purse (see the header).
func land_coin() -> void:
	_pending = maxi(0, _pending - 1)
	_shown += 1
	if _pending == 0:
		_shown = _purse()
	_refresh_label()
	_thump()


func _on_gold_changed(_v: int) -> void:
	if _pending > 0:
		return   # the coins in flight are the ones allowed to move this number
	_shown = _purse()
	_refresh_label()


func _purse() -> int:
	return GameData.current_run.gold if GameData.current_run != null else 0


func _refresh_label() -> void:
	_count.text = str(_shown)
	UIScale.tip(self, Loc.t("combat.gold_bag_tip", {"n": _shown}))


# A coin has weight: the bag takes it with a squash-and-settle and a brief warm flare, so a
# purse filling from a long kill reads as a sequence of arrivals rather than a ticking number.
func _thump() -> void:
	if _icon == null or _icon.size == Vector2.ZERO:
		return
	_icon.pivot_offset = _icon.size * 0.5
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_icon, "scale", Vector2(1.16, 0.88), 0.07).set_ease(Tween.EASE_OUT)
	tw.tween_property(_icon, "modulate", Color(1.5, 1.35, 1.0), 0.07)
	tw.chain().tween_property(_icon, "scale", Vector2.ONE, 0.20) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_icon, "modulate", Color.WHITE, 0.20)
