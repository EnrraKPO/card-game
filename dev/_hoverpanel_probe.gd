extends Node
# Throwaway diagnostic for CardHoverPanel: does the details panel ever overlap the card it
# describes, and does it stay on screen? Run WITHOUT --headless.
#   godot --path D:\Godot\CardGame res://dev/_hoverpanel_probe.tscn
#
# Hovers cards in every corner of both grids plus a hand card, and reports the panel's rect against
# the card's. PASS = no intersection, and the panel fully inside the viewport.

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

	print("DELAY: %.2fs (attr %.2f, pref %.2f)" % [CardHoverPanel.delay(),
			GameAttributes.default_value("ux.tooltip.delay"), UxPrefs.tooltip_delay])
	# A zero wait keeps the probe honest about placement rather than about timers.
	UxPrefs.tooltip_delay = 0.0

	# _place is a pure function — test it on known numbers before trusting the live run.
	var screen := Vector2(1952.404, 1080.0)
	var panel_sz := Vector2(538.0, 403.0)
	for c: Rect2 in [Rect2(1615, 50, 182, 238), Rect2(159, 50, 182, 238),
			Rect2(880, 420, 182, 238), Rect2(116, 842, 182, 238)]:
		var p: Vector2 = CardHoverPanel._place(c, panel_sz, screen)
		print("PLACE: card %s -> %s  overlaps=%s" % [c, p, c.intersects(Rect2(p, panel_sz))])

	var fails := 0
	for spot: Array in [[0, 0], [0, 3], [2, 0], [2, 3], [1, 1]]:
		fails += await _check_board(board, spot[0], spot[1])
	fails += await _check_hand(combat)
	fails += await _check_delay(board)
	print("RESULT: %s" % ["ALL CLEAR" if fails == 0 else "%d FAILURES" % fails])
	get_tree().quit()


func _check_board(board: Node, r: int, c: int) -> int:
	var unit := CardInstance.from_data(CardData.get_card("bishop"))
	board.spawn_player_card(unit, r, c)
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
	board.spawn_player_card(unit, 1, 1)
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


func _hover_and_report(card: CardUI, tag: String) -> int:
	if card == null:
		print("%s: no card" % tag)
		return 0
	card.force_hover(true)
	# The panel opens a frame later (zero wait), TooltipGrowFx takes one more to measure, and the
	# follow ticker runs at 0.05s — wait past it so the settled placement is what gets judged.
	await get_tree().create_timer(0.2).timeout
	var panel: Control = CardHoverPanel._panel
	if panel == null or not is_instance_valid(panel):
		print("%s: NO PANEL — the hover did not open one" % tag)
		card.force_hover(false)
		return 1

	var cr := card.get_global_rect()
	var pr := Rect2(panel.global_position, panel.size)
	var screen := Rect2(Vector2.ZERO, card.get_viewport_rect().size)
	var overlaps := cr.intersects(pr)
	var onscreen := screen.encloses(pr)
	print("%s: card %s | panel %s | overlaps=%s onscreen=%s" % [tag, cr, pr, overlaps, onscreen])

	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			"res://dev/_hoverpanel_%s.png" % tag.replace(" ", "_").replace(",", "-"))

	card.force_hover(false)
	await get_tree().process_frame
	var gone: bool = CardHoverPanel._panel == null
	if not gone:
		print("%s: PANEL LINGERED after the pointer left" % tag)
	return (1 if overlaps else 0) + (1 if not onscreen else 0) + (0 if gone else 1)
