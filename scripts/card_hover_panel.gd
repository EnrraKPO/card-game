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
# ── It joins the hover language rather than inventing a second one ──────────────────────────
# The trigger is CardUI._set_hovered — the SAME latch that raises the yellow ring, already past the
# intent wait, already gated by _hoverable(). So the panel opens exactly on the cards that answer a
# pointer at all: not on a drag ghost, a landing phantom, the inspector's own copy or a portrait,
# none of which the player can address. One rule about what "the pointer is on this card" means,
# with the ring and the panel as two consequences of it, instead of two rules that would drift.
#
# There is no exit animation: the panel is dismissed by the pointer leaving, which has already
# happened, so it simply goes.

# The panel's clearance from the card it describes, in viewport px.
const GAP := 18.0
# How far the panel may be pushed off the screen edge before it gives up on a side (see _place).
const EDGE := 12.0

# Only one card can be under the pointer at a time, so the presenter is a single live panel — held
# statically rather than owned by a card, because the card whose panel this is may be freed (a unit
# dies under the cursor) while the panel is still on screen.
static var _panel: Control = null
static var _for_card: CardUI = null
# Cancels a pending open. Every request takes the next number; when the wait ends, a request whose
# number is stale has been overtaken (the pointer moved to another card, or left) and does nothing.
# A generation counter rather than a Timer because the wait belongs to no node that is guaranteed to
# outlive it — the card can be freed mid-wait, and a Timer parented to it would die with it.
static var _generation := 0


# "The pointer has settled on this card." Called from CardUI._set_hovered(true).
static func request(card: CardUI) -> void:
	dismiss_now()
	_generation += 1
	var mine := _generation
	var wait := delay()
	if wait > 0.0:
		await card.get_tree().create_timer(wait).timeout
		if mine != _generation:
			return   # overtaken while waiting
	# Re-asked after the wait, never assumed: the pointer may have left, or the card may have been
	# freed outright (a unit dying under the cursor), while the timer ran.
	if not is_instance_valid(card) or not card.is_inside_tree() or not card.is_hovered():
		return
	_open(card)


# "The pointer has left." Called from CardUI._set_hovered(false), and by the card on its way out of
# the tree — a card that dies under the cursor gets no exit event, and its panel would otherwise
# describe a unit that is no longer on the board.
static func dismiss(card: CardUI) -> void:
	if _for_card != card and _for_card != null:
		return   # someone else's panel is up; the late exit of a card we already left is not news
	dismiss_now()


static func dismiss_now() -> void:
	_generation += 1   # cancels any wait in flight
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	_for_card = null


static func _open(card: CardUI) -> void:
	# Built by the CARD, not here: which of the shared builder's options this view wants (its cost
	# visibility, its unreality) are facts about that card view, and asking it keeps them there.
	var panel := card.build_details_panel()
	if panel == null:
		return
	_panel = panel
	_for_card = card
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

	# MEASURED A FRAME LATE, BOTH OF THEM. A freshly built panel reports its minimum size only once
	# its containers have run, and the card may be just as fresh (a unit spawned into a slot the
	# frame before). Placing against either one early puts the panel somewhere that was true of
	# nothing — which showed up as a panel landing squarely on the card it was supposed to clear.
	await card.get_tree().process_frame
	if not is_instance_valid(panel):
		return   # dismissed while we waited; the panel is already freed
	if not is_instance_valid(card) or not card.is_hovered():
		dismiss_now()
		return
	_follow(panel, card)
	# The arrival: it grows out of the corner nearest the card (see TooltipGrowFx). Now that the
	# panel is guaranteed to sit clear of the card, that corner is always the one facing it.
	Vfx.play(TooltipGrowFx.ENTRY, panel, {"anchor": card})


# KEEPS THE PANEL BESIDE THE CARD, rather than beside where the card was when it opened.
#
# "Never over the card" is a promise about a relationship between two rects, and the panel is not
# the authority on either of them: the board relayouts, a hovered hand card is still rising as the
# panel opens, a fight shoves a unit sideways. Placing once and trusting it is the same mistake as
# any other cached fact about somebody else — so the panel ASKS, on the same 0.05s ticker every
# other glued overlay in the game uses (see Vfx._glue), and re-places only when the answer moved.
static func _follow(panel: Control, card: CardUI) -> void:
	var last := Rect2()
	var sync := func() -> void:
		if not is_instance_valid(card) or not is_instance_valid(panel) or not card.is_inside_tree():
			return
		var rect := card.get_global_rect()
		if rect == last:
			return
		last = rect
		panel.size = panel.get_combined_minimum_size()
		panel.global_position = _place(rect, panel.size, card.get_viewport_rect().size)
	sync.call()
	var ticker := Timer.new()
	ticker.wait_time = 0.05
	ticker.autostart = true
	panel.add_child(ticker)
	ticker.timeout.connect(sync)


# WHERE THE PANEL SITS: beside the card, never over it.
#
# Sides are tried in order — right, left, below, above — and the first that fits the panel whole
# wins. Horizontal before vertical because a card and its details read side by side everywhere else
# in the game (the inspector, the forge), and because a board card almost always has more room
# across than under it.
#
# If no side fits, the roomiest one is taken anyway and the panel is clamped on screen. That can
# only happen when the panel is nearly as large as the viewport, and a panel half off the screen is
# worse than one that has to overlap a little — being READABLE outranks being clear of the card.
static func _place(card_rect: Rect2, panel_size: Vector2, screen: Vector2) -> Vector2:
	var room := {
		"right":  screen.x - card_rect.end.x - GAP,
		"left":   card_rect.position.x - GAP,
		"below":  screen.y - card_rect.end.y - GAP,
		"above":  card_rect.position.y - GAP,
	}
	var best := "right"
	for side: String in ["right", "left", "below", "above"]:
		var need: float = panel_size.x if side in ["right", "left"] else panel_size.y
		if float(room[side]) >= need:
			best = side
			break
		if float(room[side]) > float(room[best]):
			best = side

	var pos := Vector2.ZERO
	match best:
		"right": pos = Vector2(card_rect.end.x + GAP, _centred(card_rect.position.y,
				card_rect.size.y, panel_size.y, screen.y))
		"left":  pos = Vector2(card_rect.position.x - GAP - panel_size.x,
				_centred(card_rect.position.y, card_rect.size.y, panel_size.y, screen.y))
		"below": pos = Vector2(_centred(card_rect.position.x, card_rect.size.x, panel_size.x,
				screen.x), card_rect.end.y + GAP)
		_:       pos = Vector2(_centred(card_rect.position.x, card_rect.size.x, panel_size.x,
				screen.x), card_rect.position.y - GAP - panel_size.y)
	# Clamped on BOTH axes: the cross axis was only centred on the card and may hang off an edge,
	# and the main axis needs it too on the give-up path above. Clamping the main axis is what may
	# push the panel back over the card — accepted, and only when nothing else would fit.
	return Vector2(
		clampf(pos.x, EDGE, maxf(EDGE, screen.x - panel_size.x - EDGE)),
		clampf(pos.y, EDGE, maxf(EDGE, screen.y - panel_size.y - EDGE)))


# The panel's start on one axis so its middle lines up with the card's, kept on screen.
static func _centred(card_start: float, card_len: float, panel_len: float, screen_len: float) -> float:
	var at := card_start + card_len * 0.5 - panel_len * 0.5
	return clampf(at, EDGE, maxf(EDGE, screen_len - panel_len - EDGE))


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
