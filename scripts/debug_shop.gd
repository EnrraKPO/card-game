extends Control

# Debug-only acquisition screen: grants ANY relic or charm into the current run for free, to
# stress-test content. Reached from the map's bottom bar. Offers are rendered through the unified
# Grant/ItemKind layer (chip + name), but granting is done directly so it bypasses gold AND the
# relic capacity cap (a relic can still only be owned once). Charms are free and repeatable.

func _ready() -> void:
	_build()


func get_chrome() -> Dictionary:
	return {"title": "Debug — Acquire Items", "exit": _leave, "show_footer": true}


func _build() -> void:
	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(body)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 20)
	scroll.add_child(col)

	col.add_child(_section("Relics", "relic", _ids(RelicData.all())))
	col.add_child(_section("Charms", "charm", _ids(CharmData.all())))


# Sorted ids from a *Data.all() values array (RelicData / CharmData), for a stable display order.
func _ids(defs: Array) -> Array:
	var ids: Array = []
	for d in defs:
		ids.append(d.id)
	ids.sort()
	return ids


func _section(title: String, kind: String, ids: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = "  %s  (%d)" % [title, ids.size()]
	lbl.add_theme_font_size_override("font_size", 18)
	box.add_child(lbl)

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 16)
	flow.add_theme_constant_override("v_separation", 16)
	box.add_child(flow)

	for id: String in ids:
		flow.add_child(_make_slot(kind, id))
	return box


func _make_slot(kind: String, id: String) -> Control:
	var grant := Grant.make(kind, id)
	var slot := VBoxContainer.new()
	slot.custom_minimum_size = Vector2(150, 0)
	slot.add_theme_constant_override("separation", 6)
	slot.alignment = BoxContainer.ALIGNMENT_CENTER

	var ui := grant.make_ui()
	ui.size_flags_horizontal = SIZE_SHRINK_CENTER
	slot.add_child(ui)

	var name_lbl := Label.new()
	name_lbl.text = grant.display_name()
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.custom_minimum_size.x = 140
	slot.add_child(name_lbl)

	var btn := Button.new()
	btn.pressed.connect(func() -> void:
		_grant(kind, id)
		_refresh_button(btn, kind, id))
	_refresh_button(btn, kind, id)
	slot.add_child(btn)
	return slot


# Grant directly into the run, bypassing gold and relic capacity (debug). Relics stay unique;
# charms stack. Both persist immediately.
func _grant(kind: String, id: String) -> void:
	var run := GameData.current_run
	if run == null:
		return
	if kind == "relic":
		if id not in run.relics:
			run.relics.append(id)
			GameData.rebuild_modifiers()   # fold the relic's effects into the live run
			GameData.save_run()
	else:
		Grant.make("charm", id).apply()    # appends to run.charms + saves


func _refresh_button(btn: Button, kind: String, id: String) -> void:
	var run := GameData.current_run
	if kind == "relic":
		var owned := run != null and id in run.relics
		btn.text = "Owned" if owned else "Get"
		btn.disabled = owned
	else:
		var n := run.charms.count(id) if run != null else 0
		btn.text = "Get  (have %d)" % n
		btn.disabled = false


func _leave() -> void:
	Nav.goto("res://scenes/map.tscn")
