extends Control

# The selected save's hub ("game world"): surfaces that slot's meta-progression and
# launches its single run — Continue if one's in progress, otherwise start fresh.
# The meta panels (Upgrades / Decks / Lab) each open their own screen.
#
# Layout is PROPORTIONAL screen-coverage, not pixels: a resources sidebar + an actions column split
# the width by stretch-ratio, and the actions (meta button row / primary / abandon) divide the height
# by stretch-ratio. Everything EXPANDs to fill its share, separated by breathing gaps — so it fills
# the screen, big and balanced, identically on any resolution. No empty margins for their own sake.

# Feature flag: the Collection screen is hidden for now. Flip to true to re-surface its hub button.
const SHOW_COLLECTION := false

var _confirm_abandon: ConfirmationDialog


func get_chrome() -> Dictionary:
	return {"title": Loc.t("game_world.realm_title", {"name": GameData.username}),
		"exit": func(): Nav.goto("res://scenes/game_slots.tscn"), "show_footer": true}


func _ready() -> void:
	# Reached without a selected save (e.g. a stale direct load) — bounce to save select.
	if GameData.current_profile == null or GameData.current_slot < 0:
		Nav.goto.call_deferred("res://scenes/game_slots.tscn")
		return

	Sfx.music("music_title")   # the hub is home — the title bed, ambience off
	Sfx.ambience("")

	# Rebuild if the form factor flips (e.g. previewing mobile by resizing in the editor).
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)

	# The hub fills the body below the shared header (the realm name sits in it).
	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(body)

	# Width split: resources sidebar (~28%) | actions column (the rest), both full height.
	var main := HBoxContainer.new()
	main.size_flags_horizontal = SIZE_EXPAND_FILL
	main.size_flags_vertical = SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 28)
	body.add_child(main)

	var sidebar := _build_loadout_panel()
	sidebar.size_flags_horizontal = SIZE_EXPAND_FILL
	sidebar.size_flags_stretch_ratio = 1.0
	sidebar.size_flags_vertical = SIZE_EXPAND_FILL
	main.add_child(sidebar)

	var actions := VBoxContainer.new()
	actions.size_flags_horizontal = SIZE_EXPAND_FILL
	actions.size_flags_stretch_ratio = 2.6
	actions.size_flags_vertical = SIZE_EXPAND_FILL
	actions.add_theme_constant_override("separation", 28)
	main.add_child(actions)

	# Height split inside actions: meta row | primary | abandon, each filling its ratio of the height.
	var has_run := GameData.slot_has_run(GameData.current_slot)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	row.size_flags_vertical = SIZE_EXPAND_FILL
	row.size_flags_stretch_ratio = 2.0
	row.add_theme_constant_override("separation", 28)
	actions.add_child(row)
	row.add_child(_meta_button(Loc.t("game_world.upgrades"), "res://scenes/upgrades_screen.tscn"))
	row.add_child(_meta_button(Loc.t("game_world.decks"), "res://scenes/deck_screen.tscn"))
	if SHOW_COLLECTION:
		row.add_child(_meta_button(Loc.t("game_world.collection"), "res://scenes/collection_screen.tscn"))
	var lab_btn := _meta_button(Loc.t("game_world.lab"), "res://scenes/lab_screen.tscn")
	row.add_child(lab_btn)
	if _lab_is_new():
		_mark_button_new(lab_btn)

	var embark := ScreenUI.action_button(Loc.t("game_world.continue_run") if has_run else Loc.t("game_world.embark"), _on_embark,
		Vector2.ZERO, 44, ScreenUI.CHROME_CONFIRM)
	embark.size_flags_horizontal = SIZE_EXPAND_FILL
	embark.size_flags_vertical = SIZE_EXPAND_FILL
	embark.size_flags_stretch_ratio = 2.3
	actions.add_child(embark)

	if has_run:
		var abandon := ScreenUI.action_button(Loc.t("game_world.abandon"), func(): _confirm_abandon.popup_centered(),
			Vector2.ZERO, 28, ScreenUI.CHROME_DANGER)
		abandon.size_flags_horizontal = SIZE_EXPAND_FILL
		abandon.size_flags_vertical = SIZE_EXPAND_FILL
		abandon.size_flags_stretch_ratio = 1.2
		actions.add_child(abandon)

	_confirm_abandon = ConfirmationDialog.new()
	_confirm_abandon.title = Loc.t("game_world.abandon")
	_confirm_abandon.dialog_text = Loc.t("game_world.abandon_confirm")
	_confirm_abandon.confirmed.connect(_on_abandon_confirmed)
	ScreenUI.wire_modal_cues(_confirm_abandon)
	add_child(_confirm_abandon)

	# Any milestone earned mid-run celebrates here, where its Lab nudge is actionable — deferred a
	# frame so the modal settles over the fully-built hub.
	_show_pending_celebration.call_deferred()


# ── FTUE: milestone celebration + Lab "New" badge ─────────────────────────────────────

# Drains ONE queued achievement celebration (the rest, if any, wait for the next hub visit) and
# shows its modal. Persists the drain so it never re-fires.
func _show_pending_celebration() -> void:
	var profile := GameData.current_profile
	if profile == null:
		return
	var id := profile.pop_celebration()
	if id == "":
		return
	GameData.save_profile()
	Achievements.celebrate(id, self)


# The Lab button wears a "New" badge once the player has earned their first King Piece (the
# first-match milestone) until they first open the Lab.
func _lab_is_new() -> bool:
	var profile := GameData.current_profile
	return profile != null and not profile.lab_visited \
		and profile.has_achievement(Achievements.FIRST_MATCH)


# Pins a small glowing "NEW" pill to a button's top-right corner and gives it an attention glow.
func _mark_button_new(btn: Button) -> void:
	Vfx.attach("map_forge_alert_glow", btn)   # the same attention glow the map's Forge button uses

	var badge := Label.new()
	badge.text = Loc.t("common.new")
	badge.add_theme_font_size_override("font_size", 20)
	badge.add_theme_color_override("font_color", Color(0.12, 0.1, 0.02))
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = Materials.color(Materials.piece_id("king"))
	style.set_corner_radius_all(10)
	style.set_content_margin_all(6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	badge.add_theme_stylebox_override("normal", style)
	# Pin it inside the button's top-right corner (grow left/down from that corner, inset a touch
	# so the whole pill stays within the button and never clips against the screen edge).
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	badge.grow_vertical = Control.GROW_DIRECTION_END
	badge.offset_right = -12
	badge.offset_top = 12
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(badge)


func _build_loadout_panel() -> Control:
	var profile := GameData.current_profile
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = ScreenUI.SURFACE_COLOR
	style.border_color = ScreenUI.SURFACE_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(0)
	panel.add_theme_stylebox_override("panel", style)
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	var deck := profile.get_selected_deck()
	var king := CardData.get_card(deck.king_id) if deck != null else null
	var king_name: String = king.display_name if king != null else profile.get_selected_king()
	_add_stat(box, Loc.t("game_world.stat_king"), king_name)
	_add_stat(box, Loc.t("game_world.stat_deck"), Loc.t("game_world.deck_cards", {"n": deck.cards.size() if deck != null else 0}))
	box.add_child(ScreenUI.experience_bar(profile))

	# Crafting resources earned from runs (essences / King Pieces) — scrolls within its own share
	# of the sidebar instead of growing unbounded and forcing the whole row (sidebar + actions
	# column) taller than the screen, which pushed the actions column's own bottom button
	# (Abandon run) down under the footer.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var mat_box := VBoxContainer.new()
	mat_box.add_theme_constant_override("separation", 10)
	mat_box.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(mat_box)
	for id: String in profile.materials.ids():
		var n := profile.materials.count(id)
		if n > 0:
			_add_stat(mat_box, Materials.display_name(id), str(n))
	return panel


func _add_stat(box: VBoxContainer, key: String, value: String) -> void:
	var lbl := Label.new()
	lbl.text = "%s:  %s" % [key, value]
	lbl.add_theme_font_size_override("font_size", 24)
	box.add_child(lbl)


# A meta-progression button that expands to fill its share of the top row.
func _meta_button(label: String, scene_path: String) -> Button:
	var btn := ScreenUI.action_button(label, Callable(), Vector2.ZERO, 34, ScreenUI.CHROME_NEUTRAL)
	btn.size_flags_horizontal = SIZE_EXPAND_FILL
	btn.size_flags_vertical = SIZE_EXPAND_FILL
	if scene_path.is_empty():
		btn.disabled = true
		UIScale.tip(btn, Loc.t("common.coming_soon"))
	else:
		btn.pressed.connect(func(): Nav.goto(scene_path))
	return btn


func _on_embark() -> void:
	# Continuing an in-progress run keeps its existing deck snapshot — no choice to make.
	# A fresh run goes through the deck-selection screen, which sets the run deck and launches.
	if GameData.slot_has_run(GameData.current_slot):
		GameData.load_run()
		Nav.goto("res://scenes/map.tscn")
	else:
		Nav.goto("res://scenes/deck_select_screen.tscn")


func _on_abandon_confirmed() -> void:
	GameData.end_run()
	Nav.goto("res://scenes/game_world.tscn")
