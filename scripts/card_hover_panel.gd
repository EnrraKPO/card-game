class_name CardHoverPanel
extends RefCounted

# THE card-details panel's presenter: it decides WHEN the panel appears, WHERE it sits, and when it
# goes. The panel's contents are still the shared CardTooltip, so every surface reads a card
# identically; only the delivery is ours.
#
# ── Why this is not Godot's tooltip any more ────────────────────────────────────────────────
# It was, and the engine's tooltip is a fine thing when a tooltip is what you want. This is not one:
#
#   * A tooltip belongs to the CURSOR — the engine places it at the pointer plus an offset. This
#     panel belongs to the CARD. Where it lands must not depend on which pixel of a unit you
#     happened to point at, and a 540-wide panel dropped at the cursor lands squarely on top of the
#     very card it is describing.
#   * How long the pointer must rest before it opens is a SETTING (see delay). The engine reads
#     gui/timers/tooltip_delay_sec once, when the viewport is built, and exposes no way to change it
#     afterwards — so a settings screen could not move it without a restart.
#
# Both of those are placement and timing, which is all a tooltip really is, so once both have to be
# ours there is nothing left of the engine's to ride.
#
# ── THE PANEL IS A PICTURE OF THE HOVER. It is not an object with a life of its own ─────────
# There is ONE input: `follow(card)`, meaning "the hovered card is now this one (or nobody)". It is
# called by CardUI's hover latch — the single place that knows which view the pointer is addressing
# (CardUI.hovered_view) — and by nothing else in the game. The panel is whatever that fact says.
#
# THIS REPLACED A REQUEST/DISMISS PROTOCOL, and the difference is not cosmetic. Before, any card
# could send `dismiss`, so the presenter had to work out whether the sender owned the panel — and it
# could not, because during the open delay it had not recorded an owner yet. Cards that had never
# been hovered sent it too: CardUI fires one on NOTIFICATION_PREDELETE, and the panel is FULL of
# CardUIs (the enlarged preview, an AbilityWidget per ability — all CardUI). So freeing one panel
# made its own children cancel the next card's pending panel, and hovering straight from one card to
# another showed nothing at all. Every part of that bug was ownership arbitration. With one input
# from one authority there is no ownership question to get wrong, so none of it exists any more.
#
# There is no exit animation: the panel goes when the hover does, which has already happened.

# The panel's clearance from the card it describes, in viewport px — applied on BOTH axes, since the
# panel sits off a corner rather than beside an edge (see _layout).
const GAP := 18.0
# The card corners the panel may sit off, in the order they are tried: upper-right first, then
# CLOCKWISE around the card. See _layout for why that order.
const CORNERS := ["upper_right", "lower_right", "lower_left", "upper_left"]
# How close to the screen edge the panel may be pushed before it is clamped back on (see _layout).
const EDGE := 12.0

# The card the panel is FOR — set the instant the hover moves, not when the panel finishes opening.
# That is the whole point: through the open delay this already names the right card, so there is
# never a window where "whose panel is this" has no answer. It was the absence of exactly that
# window's answer that the old ownership guard tried and failed to paper over.
static var _for_card: CardUI = null
# The live panel, held statically rather than owned by a card: the card may be freed (a unit dying
# under the cursor) while its panel is still on screen.
static var _panel: Control = null
# Which hover the in-flight open belongs to. An open is several awaits long — a delay, a settle, a
# layout — and the hover can move at any point in it. Each step re-checks this and abandons quietly
# if it has moved on, which is how an obsolete open stops without having to be told to.
#
# NOT the old "generation" counter under a new name. That one could be bumped by any card in the
# game and so became a way for strangers to cancel each other; this is bumped in exactly one place,
# by the one function that changes what the panel is for.
static var _epoch := 0


# ── THE ONLY INPUT ──────────────────────────────────────────────────────────────────────────
# "The hovered card is now this one" — or null for "nothing is hovered". Called by CardUI's hover
# latch and by nothing else. Idempotent: being told the same card again is not news.
static func follow(card: CardUI) -> void:
	if card == _for_card:
		return
	_epoch += 1          # abandons any open still in flight for the previous card
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	_for_card = card
	if card != null:
		_open(card, _epoch)


static func _open(card: CardUI, epoch: int) -> void:
	var wait := delay()
	if wait > 0.0:
		await card.get_tree().create_timer(wait).timeout
		if epoch != _epoch:
			return   # the hover moved while we waited
	# The card may have been freed outright (a unit dying under the cursor) while the timer ran. Its
	# PREDELETE releases the hover, so the epoch check above usually catches this first; this is the
	# belt to that braces.
	if not is_instance_valid(card) or not card.is_inside_tree():
		return
	# Built by the CARD, not here: which of the shared builder's options this view wants (its cost
	# visibility, its unreality) are facts about that card view, and asking it keeps them there.
	var panel := card.build_details_panel()
	if panel == null:
		return
	_panel = panel
	# PARKED BEFORE IT CAN EVER DRAW. Placement needs a laid-out panel (see below), which costs a
	# frame, and a panel that spent that frame visible would flash at full size in the wrong place —
	# the exact thing this whole change is meant to stop. TooltipGrowFx parks it again when it takes
	# over; doing it here too is what makes the frame in between safe.
	panel.scale = Vector2.ZERO
	panel.modulate.a = 0.0
	# The overlay BAND above this card's own canvas layer, so the panel clears the board but still
	# sits under anything layered over it (a modal's scrim) — the same rule every other floating
	# cue in the game follows. See Vfx.overlay_layer_for.
	Vfx.overlay_layer_for(card).add_child(panel)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE   # a read, never a thing to point at

	# MEASURED LATE, AND NOT ON A FIXED SCHEDULE. A freshly built panel reports its minimum size only
	# once its containers have run, and the card may be just as fresh (a unit spawned into a slot the
	# frame before). Placing against either one early puts the panel somewhere that was true of
	# nothing — which showed up as a panel landing squarely on the card it was supposed to clear.
	if not await _settled(panel, card, epoch):
		return
	_follow(panel, card)
	# The arrival: it unfolds out of the panel corner facing the card (see TooltipGrowFx). The origin
	# is STATED rather than left to be measured — _follow just chose which corner of the card to sit
	# off, which is the same decision, and re-deriving it from rects read while the panel is parked at
	# zero scale is exactly how it used to come out wrong.
	Vfx.play(TooltipGrowFx.ENTRY, panel, {"anchor": card, "pivot": panel.pivot_offset})


# HOW MANY FRAMES the panel's size is allowed to keep moving before we place it anyway. Generous
# because it costs nothing — the panel is parked at zero scale throughout, so a settle that takes
# four frames is four frames of nothing on screen, not four frames of something wrong.
const SETTLE_FRAMES := 8


# Waits until the panel knows how big it is, and answers whether it is still wanted.
#
# ONE frame used to be the rule here, and one frame is not enough. The details column is built from
# RichTextLabels with fit_content, whose minimum height is whatever the text server last laid out —
# and with inline keyword chips (TextIcons) in the text, that answer keeps changing for a frame or
# two after the first. A Control silently grows its own size to meet a minimum that arrives late, so
# a panel placed and grown against the early number did BOTH of the things this was reported for: it
# jumped bigger just as the growth finished, and it pivoted about a point measured on a rect that no
# longer existed. Neither is a placement bug — both are placing against a number still in motion.
#
# So the size is watched rather than sampled: unchanged across two consecutive frames means the
# containers have stopped, and only then is the panel worth placing. The cap is there so a panel
# that never settles (an animating child) still arrives, one frame late, instead of never.
static func _settled(panel: Control, card: CardUI, epoch: int) -> bool:
	var last := Vector2(-1.0, -1.0)
	for _i in SETTLE_FRAMES:
		await card.get_tree().process_frame
		# ABANDONED, never torn down from here. If the hover has moved on, follow() has already freed
		# this panel and built whatever replaced it — reaching for the shared state now would undo
		# somebody else's work. An obsolete open's only job is to stop.
		if epoch != _epoch or not is_instance_valid(panel):
			return false
		if not is_instance_valid(card) or not card.is_inside_tree():
			return false
		var want := panel.get_combined_minimum_size()
		if want == last:
			break
		last = want
	return true


# KEEPS THE PANEL BESIDE THE CARD, rather than beside where the card was when it opened.
#
# "Never over the card" is a promise about a relationship between two rects, and the panel is not
# the authority on either of them: the board relayouts, a hovered hand card is still rising as the
# panel opens, a fight shoves a unit sideways. Placing once and trusting it is the same mistake as
# any other cached fact about somebody else — so the panel ASKS, on the same 0.05s ticker every
# other glued overlay in the game uses (see Vfx._glue), and re-places only when the answer moved.
static func _follow(panel: Control, card: CardUI) -> void:
	# ⚠ AN ARRAY, NOT TWO LOCALS, AND THE REASON MATTERS. A GDScript lambda captures the locals it
	# closes over BY VALUE, and every call sees the value as it was when the lambda was BUILT —
	# assigning to a captured local inside changes nothing anyone will ever read again. This guard was
	# written as two plain locals and so never guarded anything: it compared against the empty Rect2
	# it started with, every time, and re-placed the panel on every one of the 20 ticks a second for
	# as long as the pointer rested. Silent, because re-placing to the same spot is invisible — until
	# a write lands mid-arrival, when the panel's own scale tween is deforming the very transform
	# `global_position` is resolved through, and the answer comes back a pixel or two off. That is
	# precisely the "jittery adjustment after the transition finishes" this was reported for: not one
	# adjustment but forty, each landing somewhere slightly different while the growth ran.
	#
	# An Array is a REFERENCE, so the copy the lambda holds and the one out here are the same storage
	# and a write inside is a write everyone sees. [0] = the card rect last placed against, [1] = the
	# panel size, [2] = which corner of the card it settled off (see _layout — the choice is sticky).
	var last: Array = [Rect2(), Vector2(-1.0, -1.0), ""]
	var sync := func() -> void:
		if not is_instance_valid(card) or not is_instance_valid(panel) or not card.is_inside_tree():
			return
		var rect := card.get_global_rect()
		# BOTH rects, not just the card's. Where the panel goes is a fact about the pair of them, so a
		# panel that changed size is exactly as out of place as a card that moved — and the panel is no
		# more the authority on its own final size than it is on the card's position (a status pip
		# arrives, a charm is attached, the text server re-flows a chip). It asks about itself on the
		# same tick it asks about the card.
		# The MINIMUM size, which is the number the placement is actually made of — and the one that
		# moves. `size` only ever auto-grows to meet a rising minimum and never follows it back down,
		# so a panel whose contents are still settling can look perfectly still through `size` while
		# what it is really asking for is still changing.
		var want := panel.get_combined_minimum_size()
		if rect == last[0] and want == last[1]:
			return
		var screen := card.get_viewport_rect().size
		var plan := _layout(rect, want, screen, String(last[2]))
		last[0] = rect
		last[1] = want
		last[2] = String(plan["corner"])
		panel.size = want
		_put(panel, plan["pos"] as Vector2)
		# The growth's origin travels WITH the placement — the two are one statement, and a panel that
		# moved to a different corner of the card mid-arrival would otherwise still be unfolding out of
		# the corner it no longer occupies.
		panel.pivot_offset = plan["pivot"] as Vector2
	sync.call()
	var ticker := Timer.new()
	ticker.wait_time = 0.05
	ticker.autostart = true
	panel.add_child(ticker)
	ticker.timeout.connect(sync)


# PUTS THE PANEL'S TOP-LEFT AT `at` (viewport space) WITHOUT ROUTING THROUGH ITS OWN TRANSFORM.
#
# ⚠ NOT `global_position = at`, and this is the subtle half of the reported jitter. `global_position`
# is resolved THROUGH the node's own pivot and scale in both directions: setting it asks "what
# position makes my current transform put my origin there", and while the arrival tween runs that
# transform is a shrunk copy of the real one. The answer comes back short by pivot × (1 − scale) —
# measured at up to 244px on a panel caught early in its growth — and the panel then slid the rest of
# the way as the scale reached 1. A placement that only becomes true once an animation finishes IS
# the "jittery adjustment after the transition"; `position` is the layout fact, which no animation
# touches, so writing it is true on the frame it happens and stays true.
#
# The panel hangs off a CanvasLayer band (Vfx.overlay_layer_for), whose transform is what maps its
# space to the screen; the Control arm is there so this stays correct if it is ever mounted elsewhere.
static func _put(panel: Control, at: Vector2) -> void:
	var parent_ci := panel.get_parent() as CanvasItem
	if parent_ci != null:
		panel.position = parent_ci.get_global_transform().affine_inverse() * at
		return
	var layer := panel.get_parent() as CanvasLayer
	panel.position = (layer.transform.affine_inverse() * at) if layer != null else at


# WHERE THE PANEL SITS: DIAGONALLY OFF A CORNER OF THE CARD, so it covers neither the card's row nor
# its column.
#
# A panel this size (about a quarter of the screen) is going to cover board either way — it has to be
# big, and it has to be read. What it must NOT bury is the card's own neighbourhood: the row it fights
# in and the column it stands in are the context you are asking about when you point at it, and a
# panel parked squarely across them answers the question by hiding the reason you asked. Sitting off
# a corner is the one placement that clears both at once.
#
# THE ORDER IS UPPER-RIGHT, THEN CLOCKWISE — lower-right, lower-left, upper-left; the first corner
# with room for the whole panel wins. Upper-right leads because that is where the empty half of the
# screen is in this game, and because a panel that rises has the card sitting under it like a
# caption. Clockwise after that is not arbitrary either: it is the shortest walk that tries the far
# side (still upper), then crosses, so the panel never hops back and forth across the card.
#
# IF NO CORNER FITS, THE COLUMN IS WHAT GETS DEFENDED. The panel keeps the horizontal side it would
# have taken and slides vertically only as far as the screen edge forces, bleeding toward the card's
# middle. Losing the row is a smaller loss than losing the column: a row is one band of the board,
# but the column is where the card itself stands, and burying the very card you are reading about is
# the one outcome with nothing to recommend it.
#
# `prefer` is the corner the panel already occupies, and it wins outright while it still fits — see
# the stickiness note in _corner_for.
#
# Returns the whole placement at once — {"corner", "pos", "pivot"} — because the three are one
# decision. Handing back a position and making the caller re-derive the pivot from it is how the
# growth ends up unfolding out of a corner the panel isn't on.
static func _layout(card_rect: Rect2, panel_size: Vector2, screen: Vector2,
		prefer := "") -> Dictionary:
	var corner := _corner_for(card_rect, panel_size, screen, prefer)
	var pos := Vector2.ZERO
	match corner:
		"upper_right": pos = Vector2(card_rect.end.x + GAP,
				card_rect.position.y - GAP - panel_size.y)
		"lower_right": pos = Vector2(card_rect.end.x + GAP, card_rect.end.y + GAP)
		"lower_left":  pos = Vector2(card_rect.position.x - GAP - panel_size.x,
				card_rect.end.y + GAP)
		_:             pos = Vector2(card_rect.position.x - GAP - panel_size.x,
				card_rect.position.y - GAP - panel_size.y)
	# THE BLEED, and it is a clamp rather than a special case. A corner placement that ran off the top
	# or bottom is pushed back on screen, which slides it toward the card's vertical middle by exactly
	# the shortfall and no more. The x clamp is a backstop for the case where the panel is wider than
	# either side of the card — nothing can be saved there, and being readable outranks being clear.
	pos = Vector2(
		clampf(pos.x, EDGE, maxf(EDGE, screen.x - panel_size.x - EDGE)),
		clampf(pos.y, EDGE, maxf(EDGE, screen.y - panel_size.y - EDGE)))
	return {"corner": corner, "pos": pos,
			"pivot": _pivot_for(corner, pos, panel_size, card_rect)}


# WHICH CORNER OF THE CARD, and STICKY once picked.
#
# `prefer` is the corner already in use and wins while it still fits. Without that, the corner is
# re-derived from scratch every time anything moves, and "does the panel fit above?" is a threshold a
# card can sit exactly on: a hand card that grows a few px on hover pushes the room under the panel's
# height for a frame or two, so the panel leaps to another corner and back — a 200px round trip
# caused by a 6px wiggle, which is what this cost before the stickiness went in. A corner once chosen
# is what the player is reading; giving it up needs a real reason, not a threshold recrossed.
static func _corner_for(card_rect: Rect2, panel_size: Vector2, screen: Vector2,
		prefer := "") -> String:
	# Each corner's room as [across, down] — how far the panel may extend away from the card on each
	# axis before it leaves the screen.
	var room := {
		"upper_right": [screen.x - card_rect.end.x - GAP, card_rect.position.y - GAP],
		"lower_right": [screen.x - card_rect.end.x - GAP, screen.y - card_rect.end.y - GAP],
		"lower_left":  [card_rect.position.x - GAP, screen.y - card_rect.end.y - GAP],
		"upper_left":  [card_rect.position.x - GAP, card_rect.position.y - GAP],
	}
	var fits := func(corner: String) -> bool:
		if not room.has(corner):
			return false
		var r: Array = room[corner]
		return float(r[0]) >= panel_size.x and float(r[1]) >= panel_size.y
	# A corner that clears the COLUMN, whether or not it also clears the row — the fallback rank.
	var fits_across := func(corner: String) -> bool:
		if not room.has(corner):
			return false
		return float((room[corner] as Array)[0]) >= panel_size.x
	if fits.call(prefer):
		return prefer
	for corner: String in CORNERS:
		if fits.call(corner):
			return corner
	# Nothing fits whole: keep the column, bleed the row (see _layout). The already-chosen corner is
	# still preferred, so a panel that is bleeding does not also wander.
	if fits_across.call(prefer):
		return prefer
	for corner: String in CORNERS:
		if fits_across.call(corner):
			return corner
	# Not even the column can be saved — the panel is wider than either side of the card. Take the
	# roomiest across and let the clamp do what it can.
	var best: String = CORNERS[0]
	for corner: String in CORNERS:
		if float((room[corner] as Array)[0]) > float((room[best] as Array)[0]):
			best = corner
	return best


# THE PANEL CORNER THE GROWTH PIVOTS ABOUT: the one nearest the card.
#
# ALWAYS A CORNER, never the truly-nearest point on the panel's edge, and the difference is the whole
# feel of the arrival. Scaling about a corner leaves an entire QUADRANT of the panel at rest — the eye
# locks onto that still region and watches the rest unfold away from it in one direction. Scaling
# about a point in the middle of an edge leaves only that one point still, and the panel flees it in
# opposite directions at once: the top and bottom edges travelling ~200px apart inside 60ms, which is
# the visual signature of a pop rather than an arrival. That was the difference reported as "it pops
# out violently", and it is why the placement above works so hard to keep the card diagonal — a
# corner origin only tells the truth when the card is actually off that corner.
#
# Measured against the FINAL rect, so a placement that had to bleed still pivots about whatever corner
# genuinely ended up closest. Ties go to `corner`'s own corner: it is the one the placement intended,
# and a tie means the two are equally honest, so the intended one breaks it rather than a rounding
# error (which is exactly how the old nearest-corner rule went wrong).
static func _pivot_for(corner: String, pos: Vector2, panel_size: Vector2,
		card_rect: Rect2) -> Vector2:
	var intended := {
		"upper_right": Vector2(0.0, panel_size.y),   # panel is up-right; its BOTTOM-left faces the card
		"lower_right": Vector2.ZERO,                 # down-right; its top-left faces
		"lower_left":  Vector2(panel_size.x, 0.0),   # down-left; its top-RIGHT faces
		"upper_left":  panel_size,                   # up-left; its bottom-right faces
	}.get(corner, panel_size * 0.5) as Vector2
	var toward := card_rect.get_center()
	var best := intended
	var best_d := (pos + intended).distance_squared_to(toward)
	for c: Vector2 in [Vector2.ZERO, Vector2(panel_size.x, 0.0),
			Vector2(0.0, panel_size.y), panel_size]:
		var d := (pos + c).distance_squared_to(toward)
		if d < best_d:   # strict, so an equal distance keeps the intended corner
			best_d = d
			best = c
	return best


# ── The wait ────────────────────────────────────────────────────────────────────────────────
# How long the pointer must rest on a card before its details open, in seconds. 0 opens on the
# frame the hover latches.
#
# TWO knobs, one answer, exactly as the pacing dial works (see Vfx.overlap): `ux.tooltip.delay` is
# the SHIPPED number, authored in the Tool's Tuning tab, and UxPrefs.tooltip_delay is the player
# overriding it for themselves. A player who has never touched the setting follows the tuning, so
# retuning the game still reaches them.
static func delay() -> float:
	if UxPrefs.tooltip_delay >= 0.0:
		return UxPrefs.tooltip_delay
	return maxf(0.0, GameAttributes.default_value("ux.tooltip.delay"))
