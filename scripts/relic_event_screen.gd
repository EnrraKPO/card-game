extends Control

# A "relic shrine" variant of the "?" event: offers a small choice of FREE relics, granted through
# the unified ItemKind/Grant layer (see Grant / ItemKinds). Picking one — or leaving — returns to
# the map. Honours the relic capacity: at the cap, the offers show disabled.

const OFFER_COUNT := 2


func _ready() -> void:
	var compact := UIScale.is_compact()
	var center := ScreenUI.frame_centered(self, "Shrine", _finish)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 28)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "An Ancient Shrine"
	title.add_theme_font_size_override("font_size", 44 if compact else 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var blurb := Label.new()
	blurb.text = "Claim one relic to carry for the rest of your run."
	blurb.add_theme_font_size_override("font_size", 24 if compact else 18)
	blurb.modulate = Color(0.82, 0.8, 0.62)
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(blurb)

	var kind := ItemKinds.get_kind("relic")
	var ids: Array[String] = kind.offer_pool(OFFER_COUNT, null) if kind != null else ([] as Array[String])

	if ids.is_empty():
		var none := Label.new()
		none.text = "The shrine lies dormant. (No new relics to offer.)"
		none.add_theme_font_size_override("font_size", 22 if compact else 16)
		none.modulate = Color(0.7, 0.7, 0.75)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(none)
	else:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 36)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		vbox.add_child(row)
		for id: String in ids:
			row.add_child(_make_offer(Grant.make("relic", id), compact))


func _make_offer(grant: Grant, compact: bool) -> Control:
	var slot := VBoxContainer.new()
	slot.add_theme_constant_override("separation", 12)
	slot.alignment = BoxContainer.ALIGNMENT_CENTER

	var chip := grant.make_ui()
	chip.size_flags_horizontal = SIZE_SHRINK_CENTER
	if compact:
		chip.custom_minimum_size = Vector2(96, 96)
	slot.add_child(chip)

	var name_lbl := Label.new()
	name_lbl.text = grant.display_name()
	name_lbl.add_theme_font_size_override("font_size", 26 if compact else 18)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot.add_child(name_lbl)

	var relic := RelicData.get_relic(grant.id)
	var desc := Label.new()
	desc.text = relic.description if relic != null else ""
	desc.add_theme_font_size_override("font_size", 18 if compact else 13)
	desc.modulate = Color(0.78, 0.78, 0.84)
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(220.0 if compact else 180.0, 0)
	slot.add_child(desc)

	var take := Button.new()
	take.add_theme_font_size_override("font_size", 26 if compact else 16)
	take.custom_minimum_size = Vector2(200, 70) if compact else Vector2(150, 0)
	take.size_flags_horizontal = SIZE_SHRINK_CENTER
	if grant.can_apply():
		take.text = "Take"
		take.pressed.connect(func() -> void: _pick(grant))
	else:
		take.text = "Inventory Full"
		take.disabled = true
	slot.add_child(take)
	return slot


func _pick(grant: Grant) -> void:
	grant.apply()
	_finish()


func _finish() -> void:
	get_tree().change_scene_to_file("res://scenes/map.tscn")
