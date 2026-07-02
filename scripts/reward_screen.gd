extends Control

# Opt-in elemental-card offers: { "id": String, "btn": CheckButton, "ui": CardUI }. The matching
# element card for each essence reward is offered with an Accept/Reject toggle (Accept by default);
# accepted ones are added to the deck on finish (see _finish).
var _element_toggles: Array = []


func get_chrome() -> Dictionary:
	return {"title": "Reward", "exit": _skip, "show_footer": true}


func _ready() -> void:
	var compact := UIScale.is_compact()
	var card_size := Vector2(300, 394) if compact else Vector2(248, 326)
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 28)
	add_child(vbox)

	var title := Label.new()
	title.text = "Victory!  Choose a Reward"
	title.add_theme_font_size_override("font_size", 56 if compact else 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var gold_gained: int = GameData.current_encounter.gold_reward if GameData.current_encounter != null else 0
	var gold_lbl := Label.new()
	gold_lbl.text = "+%d Gold" % gold_gained
	gold_lbl.add_theme_font_size_override("font_size", 30 if compact else 20)
	gold_lbl.add_theme_color_override("font_color", Color("9c7a10"))
	gold_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(gold_lbl)

	# Experience was banked at combat end (GameData.apply_encounter_rewards) — show it for feedback.
	var exp_gained: int = GameData.current_encounter.exp_reward if GameData.current_encounter != null else 0
	if exp_gained > 0:
		var exp_lbl := Label.new()
		exp_lbl.text = "+%d Experience" % exp_gained
		exp_lbl.add_theme_font_size_override("font_size", 30 if compact else 20)
		exp_lbl.add_theme_color_override("font_color", Color("1f5c8a"))
		exp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(exp_lbl)

	# Crafting resources earned this fight (already banked). Each elemental essence reward also
	# grants the matching element CARD to the deck — collected here and shown as actual cards below
	# (rather than as "+1 X card" text), so the player sees exactly what entered their deck.
	var granted_cards: Array[String] = []
	var mats: Dictionary = GameData.current_encounter.material_rewards if GameData.current_encounter != null else {}
	for id: String in mats:
		var amt := int(mats[id])
		if amt <= 0:
			continue
		var mat_lbl := Label.new()
		mat_lbl.text = "+%d %s" % [amt, Materials.display_name(id)]
		mat_lbl.add_theme_font_size_override("font_size", 28 if compact else 18)
		mat_lbl.modulate = Materials.color(id)
		mat_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(mat_lbl)
		if id in Materials.ELEMENTS:
			granted_cards.append(id)

	if not granted_cards.is_empty():
		_build_element_offers(vbox, granted_cards, compact)

	var choose_lbl := Label.new()
	choose_lbl.text = "Pick one:"
	choose_lbl.add_theme_font_size_override("font_size", 26 if compact else 18)
	choose_lbl.add_theme_color_override("font_color", Color("5a4a38"))
	choose_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(choose_lbl)

	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 32)
	card_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(card_row)

	# Offers are unified Grants (cards from the reward pool, plus an optional relic), rendered and
	# applied generically through the ItemKind layer — see Grant / ItemKinds. The whole offer is
	# clickable (no separate button) to keep picking friction-free.
	var offers: Array = []
	if GameData.current_encounter != null:
		for id: String in GameData.current_encounter.reward_pool:
			offers.append(Grant.make("card", id))
		if not GameData.current_encounter.relic_offer.is_empty():
			offers.append(Grant.make("relic", GameData.current_encounter.relic_offer))

	for grant: Grant in offers:
		card_row.add_child(_make_offer(grant, card_size, compact))

	var skip_btn := ScreenUI.action_button("Skip Reward", _skip,
		Vector2(260, 84) if compact else Vector2(180, 0), 30 if compact else 18,
		ScreenUI.CHROME_NEUTRAL)
	skip_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	vbox.add_child(skip_btn)


# The element card(s) earned this fight, each offered with an Accept/Reject toggle (Accept by
# default). Accepted cards are added to the deck on finish; the essence itself is always kept.
func _build_element_offers(vbox: VBoxContainer, ids: Array[String], compact: bool) -> void:
	var recv_lbl := Label.new()
	recv_lbl.text = "Bonus elemental card"
	recv_lbl.add_theme_font_size_override("font_size", 24 if compact else 15)
	recv_lbl.add_theme_color_override("font_color", Color("5a4a38"))
	recv_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(recv_lbl)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	vbox.add_child(row)

	var recv_size := Vector2(150, 197) if compact else Vector2(98, 129)
	for id: String in ids:
		var data := CardData.get_card(id)
		if data == null:
			continue
		var slot := VBoxContainer.new()
		slot.add_theme_constant_override("separation", 6)
		slot.alignment = BoxContainer.ALIGNMENT_CENTER

		var ui := CardUI.create(CardInstance.from_data(data))
		ui.draggable = false
		ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui.custom_minimum_size = recv_size
		# Keep the card at its own width — a CardUI scales (and so grows taller) to fill extra
		# width, which would otherwise spill over the wider "Accept" toggle stacked beneath it.
		ui.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		slot.add_child(ui)

		var toggle := CheckButton.new()
		toggle.button_pressed = true   # Accept by default
		toggle.text = "Accept"
		toggle.add_theme_font_size_override("font_size", 22 if compact else 14)
		toggle.size_flags_horizontal = SIZE_SHRINK_CENTER
		toggle.toggled.connect(func(on: bool) -> void:
			toggle.text = "Accept" if on else "Reject"
			ui.modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.35)
		)
		slot.add_child(toggle)
		row.add_child(slot)

		_element_toggles.append({"id": id, "btn": toggle, "ui": ui})


# A pickable offer. Cards render as the card itself (click anywhere to pick); relics render as a
# card-sized info panel, also click-to-pick. A relic at the capacity cap is shown disabled.
func _make_offer(grant: Grant, card_size: Vector2, compact: bool) -> Control:
	if grant.kind == "card":
		var ui := grant.make_ui()
		ui.custom_minimum_size = card_size
		ui.mouse_filter = Control.MOUSE_FILTER_STOP   # the offer card captures clicks to pick
		if ui is CardUI:
			(ui as CardUI).draggable = false
			(ui as CardUI).pressed.connect(func() -> void: _pick(grant))
		return ui
	return _make_relic_offer(grant, card_size, compact)


func _make_relic_offer(grant: Grant, card_size: Vector2, compact: bool) -> Control:
	var relic := RelicData.get_relic(grant.id)
	var accent := relic.color if relic != null else Color(0.80, 0.74, 0.45)
	var pickable := grant.can_apply()

	var btn := Button.new()
	btn.custom_minimum_size = card_size
	btn.tooltip_text = grant.tooltip()
	btn.disabled = not pickable
	var style := StyleBoxFlat.new()
	style.bg_color = ScreenUI.SURFACE_DEEP
	style.set_corner_radius_all(10)
	style.set_border_width_all(3)
	style.border_color = accent
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("disabled", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = ScreenUI.SURFACE_DEEP.lightened(0.08)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)

	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 8)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(v)

	v.add_child(_offer_label(relic.letter if relic != null else "✦", 64 if compact else 44, accent.darkened(0.3)))
	v.add_child(_offer_label("RELIC", 18 if compact else 12, Color("5a4a38")))
	var name_lbl := _offer_label(grant.display_name(), 24 if compact else 17, ScreenUI.TEXT_COLOR)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.custom_minimum_size.x = card_size.x - 18
	v.add_child(name_lbl)
	var desc := _offer_label(relic.description if relic != null else "", 18 if compact else 12, Color("4a3d2e"))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size.x = card_size.x - 18
	v.add_child(desc)
	if not pickable:
		v.add_child(_offer_label("Inventory Full", 18 if compact else 12, Color("8a2020")))

	if pickable:
		btn.pressed.connect(func() -> void: _pick(grant))
	return btn


func _offer_label(text: String, font_size: int, col: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", col)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _pick(grant: Grant) -> void:
	grant.apply()
	_finish()


func _skip() -> void:
	_finish()


func _finish() -> void:
	# Gold + materials were applied at combat end (GameData.apply_encounter_rewards); here we add
	# any ACCEPTED bonus elemental cards plus whatever pick reward was already applied, then leave.
	if GameData.current_run != null:
		for entry: Dictionary in _element_toggles:
			var btn: CheckButton = entry["btn"]
			if btn.button_pressed:
				GameData.current_run.deck.append(DeckCard.make(str(entry["id"])))
	GameData.save_run()
	GameData.current_encounter = null
	Nav.goto("res://scenes/map.tscn")
