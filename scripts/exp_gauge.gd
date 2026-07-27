class_name ExpGauge
extends Control

# The experience a fight is earning, WHILE it earns it — a very narrow full-height column on
# combat's left edge, outboard of the relic strip. Every enemy that dies pays experience (see
# GameData.kill_bounty) and this is the only place that says so: no coin, no number leaving the
# corpse, just a bar that grows a little each time something falls.
#
# It shows the SAME quantity the hub and the Upgrades screen show — progress toward the next
# upgrade point (ProfileData.EXP_PER_UPGRADE_POINT) — in the same blue, so the mid-fight gauge
# and the between-screens bar are visibly one number and not two.
#
# Deliberately DISPLAY-ONLY, and deliberately ahead of the save: experience banks once, at
# combat end (Combat._handle_combat_end), because ProfileData writes the profile to disk on
# every grant and a per-kill save mid-fight is a disk write per corpse. So the gauge carries
# the running total by itself:
#
#   gauge.add_exp(3)      # animates; the profile still holds the pre-fight value
#
# Crossing a point is not a special case — the tween runs on the cumulative total and the fill
# is that total modulo the point cost, so the bar simply fills, wraps, and flares gold. The
# wrap IS the "you earned an upgrade point" cue.

const WIDTH := 26.0
const WIDTH_COMPACT := 34.0
const INSET := 4.0          # the fill's margin inside the track
const FILL_COLOR := Color(0.42, 0.72, 0.98)   # ScreenUI.experience_bar_compact's blue — same
											   # number, same colour, everywhere it appears

# The animated cumulative experience total. Fractional mid-tween: the fill reads it directly,
# so the bar moves smoothly instead of stepping per kill.
var _total: float = 0.0:
	set(v):
		var was := _total
		_total = v
		# `_armed` keeps the crossing flare for crossings EARNED HERE. Seeding the gauge with
		# the experience the player walked in holding runs through this same setter and would
		# otherwise fire the whole celebration at build time (see _ready).
		if _armed and _wrapped(was, v):
			_flare()
		queue_redraw()

var _armed := false

var _pending: int = 0      # earned this fight and not yet banked (see the header)
var _flash: float = 0.0:   # the point-crossing flare, 1 → 0
	set(v):
		_flash = v
		queue_redraw()


func _ready() -> void:
	custom_minimum_size.x = WIDTH_COMPACT if UIScale.is_compact() else WIDTH
	size_flags_vertical = SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS   # narrow, but it still carries its own tooltip
	_total = float(_banked())   # unarmed: seeding is not a crossing (see the setter)
	_armed = true
	_refresh_tip()


# What this fight has earned so far — Combat banks exactly this at the end (once, one save).
func pending() -> int:
	return _pending


# Books `amount` experience and grows the bar into it. The tween is the whole feedback: there
# is no floating number and no coin, by design — experience is the quiet half of a kill.
func add_exp(amount: int) -> void:
	if amount <= 0:
		return
	_pending += amount
	_refresh_tip()
	var tw := create_tween()
	tw.tween_property(self, "_total", float(_banked() + _pending), 0.45) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _banked() -> int:
	var p := GameData.current_profile
	if p == null:
		return 0
	# The gauge's axis is ONE point's worth of progress, but its bar rides the cumulative total
	# so a wrap animates. Points already spent are irrelevant to both.
	return p.upgrade_points * ProfileData.EXP_PER_UPGRADE_POINT + p.experience


func _refresh_tip() -> void:
	var per := ProfileData.EXP_PER_UPGRADE_POINT
	var cur := int(_banked() + _pending) % per
	var tip := Loc.t("combat.exp_tip", {"cur": cur, "max": per})
	if _pending > 0:
		tip += "\n" + Loc.t("combat.exp_earned", {"n": _pending})
	UIScale.tip(self, tip)


func _wrapped(from_v: float, to_v: float) -> bool:
	var per := float(ProfileData.EXP_PER_UPGRADE_POINT)
	return floori(to_v / per) > floori(from_v / per)


func _flare() -> void:
	Sfx.play("experience_gain")
	var tw := create_tween()
	tw.tween_property(self, "_flash", 1.0, 0.10)
	tw.tween_property(self, "_flash", 0.0, 0.55).set_trans(Tween.TRANS_SINE)


func _draw() -> void:
	var per := float(ProfileData.EXP_PER_UPGRADE_POINT)
	var frac: float = clampf(fposmod(_total, per) / per, 0.0, 1.0)

	# The track: the same dark framed column the mana gauge and relic strip wear, so the three
	# read as one family of instruments flanking the board.
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(int(size.x * 0.5))
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	draw_style_box(track, Rect2(Vector2.ZERO, size))

	var span := size.y - INSET * 2.0
	if span <= 0.0:
		return
	var h := span * frac
	var fill := StyleBoxFlat.new()
	fill.set_corner_radius_all(int((size.x - INSET * 2.0) * 0.5))
	fill.bg_color = FILL_COLOR.lerp(Color(1.0, 0.92, 0.55), _flash)   # gold at the crossing
	fill.anti_aliasing = true
	if h > 1.0:
		# Grown from the BOTTOM: a gauge that fills upward is read as accumulation without a
		# label having to say so.
		draw_style_box(fill, Rect2(INSET, INSET + span - h, size.x - INSET * 2.0, h))
		# A bright cap on the fill's leading edge — the surface of what's rising.
		var cap := Color(1, 1, 1, 0.55 + 0.35 * _flash)
		draw_line(Vector2(INSET + 1.0, INSET + span - h), Vector2(size.x - INSET - 1.0, INSET + span - h),
				cap, 2.0, true)
