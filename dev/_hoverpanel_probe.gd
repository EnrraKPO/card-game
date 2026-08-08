extends Node
# Throwaway diagnostic for CardHoverPanel: does the details panel ever overlap the card it
# describes, and does it stay on screen? Run WITHOUT --headless.
#   godot --path D:\Godot\CardGame res://dev/_hoverpanel_probe.tscn
#
# Hovers cards in every corner of both grids plus a hand card, and reports the panel's rect against
# the card's. PASS = no intersection, and the panel fully inside the viewport.

# One mid-growth capture per hovered spot (see _hover_and_report).
var _caught := {}


func _ready() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()
	var combat: Node = (load("res://scenes/combat.tscn") as PackedScene).instantiate()
	add_child(combat)

	var board: Node = null
	for _w in 400:
		await get_tree().process_frame
		board = combat.get("_board")
		if board != null and bool(board.get("placement_enabled")):
			break
	if board == null:
		print("PROBE: combat never reached placement")
		get_tree().quit()
		return

	# THE REAL POINTER HAS TO BE PARKED SOMEWHERE INERT. force_hover latches a synthetic hover, but the
	# OS cursor is still wherever the user left it, and if that is over the board it raises a genuine
	# hover of its own — which dismisses the probe's panel and opens another card's mid-measurement.
	# Read as "the panel teleported to (0,0)". Bottom-right of the hand is empty in every layout.
	DisplayServer.warp_mouse(Vector2(1200, 1060))
	await get_tree().process_frame

	print("DELAY: %.2fs (attr %.2f, pref %.2f)" % [CardHoverPanel.delay(),
			GameAttributes.default_value("ux.tooltip.delay"), UxPrefs.tooltip_delay])
	# A zero wait keeps the probe honest about placement rather than about timers.
	UxPrefs.tooltip_delay = 0.0

	# _layout is a pure function — test it on known numbers before trusting the live run. The corner
	# it names is the interesting half: upper-right wherever there is room, then clockwise.
	var screen := Vector2(1952.404, 1080.0)
	var panel_sz := Vector2(538.0, 403.0)
	for c: Rect2 in [Rect2(1615, 50, 182, 238), Rect2(159, 50, 182, 238),
			Rect2(880, 420, 182, 238), Rect2(116, 842, 182, 238)]:
		var plan: Dictionary = CardHoverPanel._layout(c, panel_sz, screen)
		var p: Vector2 = plan["pos"]
		print("PLACE: card %s -> %s corner=%s pivot=%s overlaps=%s" %
				[c, p, plan["corner"], plan["pivot"], c.intersects(Rect2(p, panel_sz))])

	var fails := 0
	for spot: Array in [[0, 0], [0, 3], [2, 0], [2, 3], [1, 1]]:
		fails += await _check_board(board, spot[0], spot[1])
	fails += await _check_hand(combat)
	fails += await _check_delay(board)
	fails += await _check_card_to_card(board)
	print("RESULT: %s" % ["ALL CLEAR" if fails == 0 else "%d FAILURES" % fails])
	get_tree().quit()


func _check_board(board: Node, r: int, c: int) -> int:
	var unit := CardInstance.from_data(CardData.get_card("bishop"))
	board.spawn_player_card(unit, BoardLocation.at(0, r, c))
	await get_tree().process_frame
	var card: CardUI = board.get_card_ui(unit)
	var bad := await _hover_and_report(card, "player %d,%d" % [r, c])
	board.remove_card(unit)
	await get_tree().process_frame
	return bad


func _check_hand(combat: Node) -> int:
	var hand: Node = combat.get("_hand")
	var cards: Array = hand.get("_hand_cards") if hand != null else []
	if cards.is_empty():
		print("HAND: no card to hover")
		return 0
	return await _hover_and_report(cards[0] as CardUI, "hand card")


# The wait: nothing at half the delay, a panel comfortably after it — and a hover that ends inside
# the wait must leave nothing behind at all.
func _check_delay(board: Node) -> int:
	UxPrefs.tooltip_delay = 0.4
	var unit := CardInstance.from_data(CardData.get_card("bishop"))
	board.spawn_player_card(unit, BoardLocation.at(0, 1, 1))
	await get_tree().process_frame
	var card: CardUI = board.get_card_ui(unit)
	var bad := 0

	card.force_hover(true)
	await get_tree().create_timer(0.2).timeout
	var early: bool = CardHoverPanel._panel != null
	await get_tree().create_timer(0.45).timeout
	var late: bool = CardHoverPanel._panel != null
	print("DELAY 0.40s: panel at 0.20s=%s (want false) | at 0.65s=%s (want true)" % [early, late])
	if early or not late:
		bad += 1
	card.force_hover(false)
	await get_tree().process_frame

	# Cancelled intent: hovered, left before the wait elapsed — nothing may open afterwards.
	card.force_hover(true)
	await get_tree().create_timer(0.15).timeout
	card.force_hover(false)
	await get_tree().create_timer(0.6).timeout
	var leaked: bool = CardHoverPanel._panel != null
	print("DELAY cancelled mid-wait: panel opened anyway=%s (want false)" % leaked)
	if leaked:
		bad += 1

	board.remove_card(unit)
	UxPrefs.tooltip_delay = 0.0
	return bad


# MOVING THE POINTER STRAIGHT FROM ONE CARD TO ANOTHER — the reported failure, and the one the
# per-card checks above could never catch because each of them releases its card before the next.
#
# The old design lost this every time. Tearing down card A's panel freed the CardUIs INSIDE it (the
# enlarged preview, an AbilityWidget per ability), each of which announced its own death to the
# presenter, and with no owner recorded for a panel that was still pending, each announcement
# cancelled card B's. So the second card in any sweep showed nothing. Repeated a few times because
# the frequency depended on how the frees landed against the delay.
func _check_card_to_card(board: Node) -> int:
	var a := CardInstance.from_data(CardData.get_card("bishop"))
	var b := CardInstance.from_data(CardData.get_card("knight"))
	board.spawn_player_card(a, BoardLocation.at(0, 1, 0))
	board.spawn_player_card(b, BoardLocation.at(0, 1, 2))
	await get_tree().process_frame
	var ca: CardUI = board.get_card_ui(a)
	var cb: CardUI = board.get_card_ui(b)
	var bad := 0

	for pass_no in 4:
		# Land on A and let its panel fully open, so there is a real one to tear down.
		ca.force_hover(true)
		await get_tree().create_timer(delay_plus(0.35)).timeout
		var got_a: bool = CardHoverPanel._panel != null and CardHoverPanel._for_card == ca
		# THE SWEEP: A released and B taken in the same frame, exactly as a pointer crossing does.
		ca.force_hover(false)
		cb.force_hover(true)
		await get_tree().create_timer(delay_plus(0.35)).timeout
		var got_b: bool = CardHoverPanel._panel != null and CardHoverPanel._for_card == cb
		print("SWEEP %d: A opened=%s (want true) | B opened straight after=%s (want true)" %
				[pass_no, got_a, got_b])
		if not got_a or not got_b:
			bad += 1
		cb.force_hover(false)
		await get_tree().process_frame

	board.remove_card(a)
	board.remove_card(b)
	await get_tree().process_frame
	return bad


# The open delay plus enough slack for the settle frames and the placement.
func delay_plus(slack: float) -> float:
	return CardHoverPanel.delay() + slack


func _hover_and_report(card: CardUI, tag: String) -> int:
	if card == null:
		print("%s: no card" % tag)
		return 0
	card.force_hover(true)
	# WATCHED FRAME BY FRAME from the moment the hover latches, not sampled once when it's over. The
	# two defects this probe now exists for are both invisible to a late sample: a panel that grows
	# bigger a frame after its arrival ends up at the right size, and a panel that unfolded out of
	# the wrong point ends up in the right place. Only the trail shows either one.
	var sizes: Array = []      # every distinct size the panel took, in order
	var moves := 0             # how many times it re-placed after the first
	var shifts: Array = []     # each re-place as "f<frame>(dx, dy)" — when and how far
	var card_trail: Array = [] # the card's own rect, whenever it changed
	var card_was := Rect2()
	var still_for := 99        # frames since the card last moved (see the excuse below)
	var unexplained := 0       # re-places the card's own movement does not account for
	var pos := Vector2.INF
	var settled_at := -1       # frame the last size change landed on
	var panel: Control = null
	for f in 40:               # ~0.66s at 60fps: past the 0.16s growth and several follow ticks
		await get_tree().process_frame
		var p: Control = CardHoverPanel._panel
		if p == null or not is_instance_valid(p):
			continue
		panel = p
		# THE MINIMUM size, not the size. `size` only auto-grows to meet a rising minimum and never
		# follows it back down, so a panel whose contents are still settling SHRINKWARDS looks perfectly
		# stable through `size` while the number the placer actually uses is still in motion.
		var mins := panel.get_combined_minimum_size()
		if sizes.is_empty() or mins != sizes[-1]:
			sizes.append(mins)
			settled_at = f
		# `position`, NOT global_position. A Control's GLOBAL position is read through its own internal
		# transform, which carries the pivot/scale offset — so a panel growing about a pivot reports a
		# sliding global origin every frame of the tween while sitting exactly where it was put. (The
		# SETTER is not symmetrical: it inverts only the parent's transform, which is why placing by
		# global_position is still correct.) Counting those as re-places made the probe cry jitter at
		# the animation itself.
		# THE RULE: the panel may move ONLY because the card moved. Its opening placement is exempt
		# (it has to get there somehow); after that, a shift on a frame whose card sat still is the
		# panel correcting itself on screen, which is the defect — whatever the arithmetic reason.
		var cnow := card.get_global_rect()
		if pos != Vector2.INF and panel.position != pos:
			moves += 1
			# The follow ticker reads the card at its own instant inside the frame, which is not this
			# one, and it only fires every 0.05s (3 frames) — so a card mid-lift is routinely caught
			# still by this sample while the ticker saw it move. The excuse therefore covers a card
			# that has moved at any point in the last few frames, not same-frame proof.
			var excused: bool = moves == 1 or still_for <= 4
			shifts.append("f%d%s%s" % [f, panel.position - pos, "" if excused else " UNEXPLAINED"])
			if not excused:
				unexplained += 1
		pos = panel.position
		still_for = 0 if cnow != card_was else still_for + 1
		# WHAT the panel is following, sampled on the same frames — a panel that moves is only ever
		# reporting that the card moved, so the card's trail is the one that names the cause.
		if cnow != card_was:
			card_trail.append("f%d %s" % [f, cnow])
		card_was = cnow
		# MID-GROWTH, caught on the way past: the settled shot below cannot show which point the panel
		# is unfolding out of, and that is the half of this the eye actually complains about.
		if panel.scale.x > 0.15 and panel.scale.x < 0.75 and not _caught.has(tag):
			_caught[tag] = true
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(
					"res://dev/_hovergrow_%s.png" % tag.replace(" ", "_").replace(",", "-"))
	if panel == null or not is_instance_valid(panel):
		print("%s: NO PANEL — the hover did not open one" % tag)
		card.force_hover(false)
		return 1

	var cr := card.get_global_rect()
	# `position`, never global_position — the latter resolves through the panel's own pivot/scale, so
	# while the growth is still running it reports the panel wherever the tween currently has it. That
	# read is why the row/column verdicts flipped the moment the duration went from 0.16s to 0.4s and
	# the tween was no longer finished by the time this measured.
	var pr := Rect2(panel.position, panel.size)
	var screen := Rect2(Vector2.ZERO, card.get_viewport_rect().size)
	var overlaps := cr.intersects(pr)
	var onscreen := screen.encloses(pr)
	print("%s: card %s | panel %s | overlaps=%s onscreen=%s" % [tag, cr, pr, overlaps, onscreen])

	# THE JITTER. One size and one placement for the panel's whole life is the pass: it was placed
	# against numbers that had stopped moving. More than one means it was placed against a guess and
	# corrected itself on screen, which is the "jittery adjustment after the transition" as reported.
	var steady: bool = sizes.size() == 1 and unexplained == 0
	print("%s: sizes %s (last change frame %d) | re-places %d %s | unexplained=%d steady=%s" %
			[tag, sizes, settled_at, moves, shifts, unexplained, steady])
	print("%s: CARD moved %d times %s" % [tag, card_trail.size(), card_trail])

	# THE NEIGHBOURHOOD. The panel sits off a CORNER of the card, so it must cover neither the column
	# the card stands in nor the row it fights in. The column is the hard promise — when nothing fits,
	# the placement gives up the row and keeps the column (see CardHoverPanel._layout), so a cleared
	# row is reported but only a covered column is a failure.
	var clears_col: bool = pr.end.x <= cr.position.x or pr.position.x >= cr.end.x
	var clears_row: bool = pr.end.y <= cr.position.y or pr.position.y >= cr.end.y
	print("%s: clears column=%s row=%s%s" %
			[tag, clears_col, clears_row, "" if clears_row else "  (bled — no corner had room)"])

	# THE PIVOT. It has to be a true CORNER of the panel — that is what leaves a whole quadrant at
	# rest and makes the growth read as unfolding in one direction rather than popping. A pivot part
	# way along an edge is the splay that read as violent.
	var piv := panel.pivot_offset
	var on_corner: bool = (is_zero_approx(piv.x) or is_equal_approx(piv.x, panel.size.x)) \
			and (is_zero_approx(piv.y) or is_equal_approx(piv.y, panel.size.y))
	# And it must be the corner NEAREST the card, or the panel unfolds away from its own subject.
	var want_piv := TooltipGrowFx.attach_point(panel, card)
	var pivot_ok: bool = on_corner and piv.is_equal_approx(want_piv)
	print("%s: pivot %s (want %s, card centre %s) on_corner=%s ok=%s" %
			[tag, piv, want_piv, cr.get_center(), on_corner, pivot_ok])

	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://dev/_hoverpanel_%s.png" % tag.replace(" ", "_").replace(",", "-"))

	card.force_hover(false)
	await get_tree().process_frame
	var gone: bool = CardHoverPanel._panel == null
	if not gone:
		print("%s: PANEL LINGERED after the pointer left" % tag)
	return (1 if overlaps else 0) + (1 if not onscreen else 0) + (0 if gone else 1) \
			+ (0 if steady else 1) + (0 if pivot_ok else 1) + (0 if clears_col else 1)
