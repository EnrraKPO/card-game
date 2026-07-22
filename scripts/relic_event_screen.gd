extends Control

# A "relic shrine" variant of the "?" event: offers a small choice of FREE relics, granted through
# the unified ItemKind/Grant layer (see Grant / ItemKinds). Picking one — or leaving — returns to
# the map. Honours the relic capacity: at the cap, the offers show disabled.

const OFFER_COUNT := 2


func get_chrome() -> Dictionary:
	return {"title": Loc.t("relic_event.title"), "exit": _finish, "show_footer": true}


func _ready() -> void:
	Sfx.music("music_special_event")
	var compact := UIScale.is_compact()
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 28)
	add_child(vbox)

	var title := Label.new()
	title.text = Loc.t("relic_event.heading")
	title.add_theme_font_size_override("font_size", 44 if compact else 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var blurb := Label.new()
	blurb.text = Loc.t("relic_event.blurb")
	blurb.add_theme_font_size_override("font_size", 24 if compact else 18)
	blurb.add_theme_color_override("font_color", Color("6b5636"))
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(blurb)

	var kind := ItemKinds.get_kind("relic")
	var ids: Array[String] = kind.offer_pool(OFFER_COUNT, null) if kind != null else ([] as Array[String])

	if ids.is_empty():
		var none := Label.new()
		none.text = Loc.t("relic_event.dormant")
		none.add_theme_font_size_override("font_size", 22 if compact else 16)
		none.add_theme_color_override("font_color", Color("5a4a38"))
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
	var desc := TextIcons.rich_label(relic.description if relic != null else "",
		18 if compact else 13, Color("4a3d2e"), true)
	desc.custom_minimum_size = Vector2(220.0 if compact else 180.0, 0)
	slot.add_child(desc)

	var take := ScreenUI.action_button("", Callable(),
		Vector2(200, 70) if compact else Vector2(150, 0), 26 if compact else 16,
		ScreenUI.CHROME_CONFIRM)
	take.size_flags_horizontal = SIZE_SHRINK_CENTER
	if grant.can_apply():
		take.text = Loc.t("relic_event.take")
		take.pressed.connect(func() -> void: _pick(grant, slot))
	else:
		take.text = Loc.t("reward.inventory_full")
		take.disabled = true
	slot.add_child(take)
	return slot


var _picked := false

func _pick(grant: Grant, source: Control = null) -> void:
	if _picked:   # the halo is awaited — don't let a second click double-grant
		return
	_picked = true
	# The relic joining the run celebrates on its offer (the entry carries the taken-sound),
	# held so the navigation right after doesn't cut it.
	if source != null and is_instance_valid(source):
		await Vfx.play("reward_relic_halo", source)
	grant.apply()
	_finish()


func _finish() -> void:
	Nav.goto("res://scenes/map.tscn")
