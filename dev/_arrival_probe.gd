extends Node
# Throwaway diagnostic for the three ARRIVAL animations. Run WITHOUT --headless (the tooltip half
# needs a real window: Godot's tooltip popup only embeds in the root viewport).
#   godot --path D:\Godot\CardGame res://dev/_arrival_probe.tscn
#
# Prints, for each: the sampled state over time. What "passing" looks like —
#   SLIDE   : offset starts near the full slot-to-slot distance and decays to 0.
#   NUMBER  : modulate.a starts at 0 and climbs to the plate's resting 1.0.
#   TOOLTIP : scale starts at 0 and climbs to 1; pivot is a CORNER (not the centre).

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

	await _probe_slide(board)
	await _probe_turn_number(board)
	await _probe_tooltip(board)
	get_tree().quit()


# ── 1. The enemy slide ─────────────────────────────────────────────────────────
func _probe_slide(board: Node) -> void:
	var foe := CardInstance.from_data(CardData.get_card("pawn"))
	board.place_enemy_card(foe, BoardLocation.at(1, 0, 0))
	await get_tree().process_frame
	await get_tree().process_frame

	var card: CardUI = board.get_card_ui(foe)
	var start := card.global_position
	var from: Vector2 = board.move_enemy_card(foe, BoardLocation.at(1, 1, 3))
	var moved: CardUI = board.get_card_ui(foe)
	print("SLIDE: from=%s (card stood at %s) — same=%s" % [from, start, from == start])
	Vfx.play("unit_move_slide", moved, {"from": from})

	# Where the card RESTS once laid out, so the offset can be read against it.
	for _i in 2:
		await get_tree().process_frame
	var samples: Array[String] = []
	for i in 14:
		samples.append("%.0f" % moved.global_position.distance_to(from))
		await get_tree().process_frame
		if i == 0 or i == 4 or i == 9:
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://dev/_arrival_slide_%d.png" % i)
	print("SLIDE: distance from origin, per frame: %s" % [", ".join(samples)])
	print("SLIDE: settled at %s (slot centre %s)" % [
			moved.global_position, (board.enemy_slots[1][3] as Control).global_position])
	board.remove_card(foe)


# ── 2. The turn number ─────────────────────────────────────────────────────────
func _probe_turn_number(board: Node) -> void:
	var unit := CardInstance.from_data(CardData.get_card("pawn"))
	board.spawn_player_card(unit, BoardLocation.at(0, 1, 1))
	await get_tree().process_frame
	var card: CardUI = board.get_card_ui(unit)

	card._refresh_turn_number(3)
	var plate: Panel = card.get("_turn_plate")
	print("NUMBER: plate visible=%s alpha at t0=%.2f" % [plate.visible, plate.modulate.a])
	var samples: Array[String] = []
	for i in 30:
		samples.append("%.2f" % plate.modulate.a)
		await get_tree().process_frame
	print("NUMBER: alpha per frame: %s" % [", ".join(samples)])

	# Re-deriving while the number is already up must NOT restart the fade.
	card._refresh_turn_number(4)
	await get_tree().process_frame
	print("NUMBER: alpha after a re-derive while shown: %.2f (must stay 1.00)" % plate.modulate.a)
	# Hidden and shown again IS a fresh arrival, and must fade from nothing a second time.
	card._refresh_turn_number(0)
	await get_tree().process_frame
	card._refresh_turn_number(2)
	await get_tree().process_frame
	print("NUMBER: alpha one frame into a SECOND arrival: %.2f (must be well under 1.00)"
			% plate.modulate.a)
	board.remove_card(unit)


# ── 3. The card-details tooltip ────────────────────────────────────────────────
func _probe_tooltip(board: Node) -> void:
	var unit := CardInstance.from_data(CardData.get_card("bishop"))
	board.spawn_player_card(unit, BoardLocation.at(0, 1, 2))
	await get_tree().process_frame
	var card: CardUI = board.get_card_ui(unit)

	# Hover it for real: the tooltip is the engine's, and only a genuine pointer rest pops it.
	# Pushed as a motion event rather than warped — warp_mouse alone does not drive the viewport's
	# GUI hover state in a headless-ish probe window.
	var at := card.get_global_rect().get_center()
	var ev := InputEventMouseMotion.new()
	ev.position = at
	ev.global_position = at
	get_viewport().push_input(ev)
	print("TOOLTIP: hovering card at %s (card rect %s) tooltip_text=%s" % [
			at, card.get_global_rect(), card.tooltip_text != ""])
	await get_tree().process_frame
	print("TOOLTIP: viewport reports hover=%s" % [get_viewport().gui_get_hovered_control()])
	var delay: float = ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5)

	var panel: Control = null
	var samples: Array[String] = []
	var waited := 0.0
	for i in 240:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if panel == null:
			panel = _find_tooltip()
			if panel != null:
				print("TOOLTIP: popped after %.2fs (delay setting %.2f)" % [waited, delay])
		if panel != null and is_instance_valid(panel):
			samples.append("%.2f" % panel.scale.x)
			if samples.size() >= 16:
				break
	if panel == null:
		print("TOOLTIP: engine tooltip never popped in the probe (%.2fs) — falling back to a"
				% waited + " replica of the engine's own wrapping, below.")
		await _probe_tooltip_replica(card)
		return
	print("TOOLTIP: scale per frame: %s" % [", ".join(samples)])
	print("TOOLTIP: size=%s pivot=%s  (centre would be %s)" % [
			panel.size, panel.pivot_offset, panel.size * 0.5])
	var wrapper := panel.get_parent() as Control
	print("TOOLTIP: wrapper=%s stylebox overridden=%s" % [
			wrapper, wrapper != null and wrapper.has_theme_stylebox_override("panel")])
	var popup := panel.get_viewport() as Window
	if popup != null:
		print("TOOLTIP: popup at %s size %s" % [popup.position, popup.size])


# What Viewport::_gui_show_tooltip does, reproduced exactly: take what _make_custom_tooltip
# returns, park it full-rect inside a PopupPanel, size the popup to the panel's minimum size, place
# it near the cursor, pop it. If the arrival behaves here it behaves on the engine's own popup.
# `place` is the popup's top-left, so the two runs put the card on opposite sides of the panel.
func _probe_tooltip_replica(card: CardUI) -> void:
	for place: Vector2i in [Vector2i(700, 460), Vector2i(150, 60)]:
		var panel := card._make_custom_tooltip("") as Control
		var popup := PopupPanel.new()
		popup.add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		get_tree().root.add_child(popup)
		popup.position = place
		popup.size = Vector2i(panel.get_combined_minimum_size())
		popup.popup()

		var samples: Array[String] = []
		for i in 16:
			await get_tree().process_frame
			samples.append("%.2f" % panel.scale.x)
			if i == 1 or i == 15:
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(
						"res://dev/_arrival_tip_%d_%d.png" % [place.x, i])
		var corners := {Vector2.ZERO: "top-left", Vector2(panel.size.x, 0.0): "top-right",
				Vector2(0.0, panel.size.y): "bottom-left", panel.size: "bottom-right"}
		print("TOOLTIP@%s: card centre %s" % [place, card.get_global_rect().get_center()])
		print("TOOLTIP@%s: scale per frame: %s" % [place, ", ".join(samples)])
		print("TOOLTIP@%s: panel %s pivot %s => %s | wrapper stripped=%s" % [place, panel.size,
				panel.pivot_offset, corners.get(panel.pivot_offset, "CENTRE (no corner!)"),
				popup.has_theme_stylebox_override("panel")])
		popup.queue_free()
		await get_tree().process_frame


# The engine parents a custom tooltip inside a popup window hung off the root viewport.
func _find_tooltip() -> Control:
	for w in get_tree().root.get_children():
		var win := w as Window
		if win == null or not win.visible:
			continue
		var found := _find_panel(win)
		if found != null:
			return found
	return null


func _find_panel(n: Node) -> Control:
	for c in n.get_children():
		if c is PanelContainer and (c as Control).get_parent() is PopupPanel:
			return c as Control
		var deep := _find_panel(c)
		if deep != null:
			return deep
	return null
