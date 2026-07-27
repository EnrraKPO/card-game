class_name ScreenGrowFx
extends RefCounted

# An ARRIVAL cue: the screen swells into existence from nothing, at the centre of the viewport.
#
# Every navigation already ends in one hook — Shell.mount plays an arrival entry on the freshly
# mounted content — and this is a second entry that hook can be pointed at, per navigation:
#
#   Nav.goto("res://scenes/reward_screen.tscn", "screen_grow_in")
#
# Its reason for existing is the treasure chest: the orb the chest releases flies to the middle
# of the screen (RewardOrbFx) and the reward screen grows out of exactly that spot, so opening
# the chest and arriving at the rewards are one motion instead of a cut.
#
# IT GROWS THE WHOLE SCREEN, FURNITURE INCLUDED. The Shell's backdrop and its header/footer bars
# are persistent — they outlive any navigation — so animating only the mounted content produced a
# screen that was already there, with its middle filling in late: the arrival read as content
# popping INSIDE a window that never left. This asks the Shell what its furniture is
# (Shell.arrival_furniture) and takes all of it with the content, which is what makes the thing
# read as a modal opening rather than a panel refreshing.
#
# The backdrop deliberately TRAILS (`bg_lag`). Content first, plate a beat behind, is the order
# that reads as the screen being pushed out of the cue that summoned it — everything moving in
# perfect lockstep looks like one flat rectangle being scaled, which is exactly what it is and
# exactly what it must not look like.
#
# The bars are faded, never scaled: they are edge-anchored furniture, and a bar scaling about the
# viewport's centre would slide in from off-square and land with a snap.

const DEF_DUR := 0.42
const DEF_DELAY := 0.20   # the beat the cue that summoned this screen gets to itself
const DEF_BG_LAG := 0.08  # how far behind the content the backdrop starts
const DEF_DIM := 0.55     # how far the departing screen dims while the modal opens over it
const DEF_OVERSHOOT := 1.05   # how far past full size the pop punches before settling back


static func play(vd: VFXData, target: Control, _opts: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	# Hidden BEFORE any await, so there is never a frame of the finished screen at full size.
	target.modulate.a = 0.0
	# One frame of patience: a just-mounted screen has a zero rect until its containers lay it
	# out, and scaling about a pivot of (0,0) would grow it out of the top-left corner.
	if target.get_global_rect().size == Vector2.ZERO:
		await target.get_tree().process_frame
		if not is_instance_valid(target) or not target.is_inside_tree():
			return
	var dur := Vfx.paced(maxf(0.05, vd.num_param("duration", DEF_DUR)), vd)
	var delay := Vfx.paced(maxf(0.0, vd.num_param("delay", DEF_DELAY)), vd)
	var lag := Vfx.paced(maxf(0.0, vd.num_param("bg_lag", DEF_BG_LAG)), vd)

	var furniture: Dictionary = Nav.shell.arrival_furniture() if Nav.shell != null else {}
	var bars: Array = furniture.get("bars", [])
	# MODAL: the screen being replaced is still mounted underneath (Shell._park_departing), and the
	# arriving screen brings its own opaque plate. The app backdrop is then NOT the thing to grow —
	# it sits behind the departing screen, and scaling it would punch a hole around a screen that
	# is still on display. Without a departing screen there is nothing to open over, and the app
	# backdrop is the plate.
	var departing: Control = furniture.get("departing")
	var plate: Control = furniture.get("plate")
	var backdrop: Control = plate if plate != null else furniture.get("background") as Control
	var modal := departing != null and is_instance_valid(departing)

	_hide(target)
	if backdrop != null:
		_hide(backdrop)
	# Under a modal the bars belong to the frame around BOTH screens, and a frame that blinks is
	# the app flickering, not a screen arriving — they stay put and only fade when there is no
	# screen behind them to keep them honest.
	if not modal:
		for b: Control in bars:
			b.modulate.a = 0.0

	# A screen born of an effect has to arrive AFTER it, not with it. Navigation happens the
	# instant the orb bursts, so growing immediately put two expansions on screen at once and the
	# eye read them as two explosions rather than one thing coming out of the other. The hold is
	# taken here — mounted, hidden, already laid out — so the burst plays alone and the screen
	# then emerges from inside it.
	# The screen underneath dims as the modal opens, exactly as a dialog's backdrop does — the dim
	# is what says "this is behind now" without moving anything the player is still looking at.
	if modal and delay > 0.0:
		var dim: float = clampf(vd.num_param("dim", DEF_DIM), 0.0, 1.0)
		# Driven from the arriving screen's tween, not the departing one's: a parked screen is
		# process-disabled, and a tween owned by a disabled node never advances.
		target.create_tween().tween_property(departing, "modulate",
				Color(dim, dim, dim, 1.0), delay).set_trans(Tween.TRANS_SINE)

	if delay > 0.0:
		await target.get_tree().create_timer(delay).timeout
		if not is_instance_valid(target) or not target.is_inside_tree():
			# Navigated away mid-hold: the furniture is the SHELL's, and leaving it at zero scale
			# (or under a parked screen) would leave the app looking broken, indefinitely.
			if Nav.shell != null:
				Nav.shell.reset_furniture()
				Nav.shell.drop_departing()
			return
		_hide(target)   # the hold is long enough for a relayout to have reset the pivot
		if backdrop != null:
			_hide(backdrop)

	var pop: float = maxf(1.0, vd.num_param("overshoot", DEF_OVERSHOOT))
	var tw := _burst_in(target, target, dur, pop, 0.0)
	if backdrop != null:
		_burst_in(target, backdrop, dur, pop, lag)
	if not modal:
		for b: Control in bars:
			var bt := b.create_tween()
			bt.tween_interval(lag)
			bt.tween_property(b, "modulate:a", 1.0, dur * 0.6)

	await tw.finished
	if is_instance_valid(target):
		target.scale = Vector2.ONE   # exact, so nothing downstream measures a rounding error
	# The backdrop trails, so the screen underneath is only fully covered once IT lands, not when
	# the content does — dropped a beat later, and never left for the next navigation to inherit.
	if Nav.shell != null:
		await target.get_tree().create_timer(lag + 0.05).timeout
		Nav.shell.drop_departing()


# THE POP. Scale 0 → slightly past full → full, in two stages.
#
# One BACK/EASE_OUT tween over the whole span is the obvious way to write this and the wrong feel:
# BACK reaches full size early and then spends the rest of its span drifting back down off its own
# overshoot, so the screen ARRIVES fast and then visibly coasts — read as sluggish no matter how
# far the duration came down. A burst is nearly all of its motion in the first instant and then a
# short, decisive settle: EXPO out for the expansion (its fastest moment is frame one) and a brief
# ease back off the overshoot. `overshoot` is how hard it punches past its own size.
#
# Owned by `owner` rather than the node being moved, so the same call can animate the Shell's
# furniture — a process-disabled or soon-to-be-freed node cannot run a tween of its own.
static func _burst_in(owner: Control, node: Control, dur: float, pop: float, delay: float) -> Tween:
	var rise := dur * 0.62
	var settle := maxf(0.02, dur - rise)
	var tw := owner.create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.tween_property(node, "scale", Vector2.ONE * pop, rise) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(node, "modulate:a", 1.0, rise * 0.55)
	tw.tween_property(node, "scale", Vector2.ONE, settle) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return tw


# Parked at nothing, about its own centre, ready to grow.
static func _hide(c: Control) -> void:
	c.pivot_offset = c.size * 0.5
	c.scale = Vector2.ZERO
	c.modulate.a = 0.0
