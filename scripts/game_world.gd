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
	return {"title": "%s's Realm" % GameData.username,
		"exit": func(): Nav.goto("res://scenes/game_slots.tscn"), "show_footer": true}


func _ready() -> void:
	# Reached without a selected save (e.g. a stale direct load) — bounce to save select.
	if GameData.current_profile == null or GameData.current_slot < 0:
		Nav.goto.call_deferred("res://scenes/game_slots.tscn")
		return

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
	row.add_child(_meta_button("Upgrades", "res://scenes/upgrades_screen.tscn"))
	row.add_child(_meta_button("Decks", "res://scenes/deck_screen.tscn"))
	if SHOW_COLLECTION:
		row.add_child(_meta_button("Collection", "res://scenes/collection_screen.tscn"))
	row.add_child(_meta_button("Lab", "res://scenes/lab_screen.tscn"))

	var embark := Button.new()
	embark.text = "Continue Run" if has_run else "Embark"
	embark.add_theme_font_size_override("font_size", 44)
	embark.size_flags_horizontal = SIZE_EXPAND_FILL
	embark.size_flags_vertical = SIZE_EXPAND_FILL
	embark.size_flags_stretch_ratio = 2.3
	embark.pressed.connect(_on_embark)
	actions.add_child(embark)

	if has_run:
		var abandon := Button.new()
		abandon.text = "Abandon run"
		abandon.add_theme_font_size_override("font_size", 28)
		abandon.size_flags_horizontal = SIZE_EXPAND_FILL
		abandon.size_flags_vertical = SIZE_EXPAND_FILL
		abandon.size_flags_stretch_ratio = 1.2
		abandon.pressed.connect(func(): _confirm_abandon.popup_centered())
		actions.add_child(abandon)

	_confirm_abandon = ConfirmationDialog.new()
	_confirm_abandon.title = "Abandon run"
	_confirm_abandon.dialog_text = "Abandon the current run? Your meta-progression is kept, but the run is lost."
	_confirm_abandon.confirmed.connect(_on_abandon_confirmed)
	add_child(_confirm_abandon)


func _build_loadout_panel() -> Control:
	var profile := GameData.current_profile
	var panel := PanelContainer.new()
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
	_add_stat(box, "King", king_name)
	_add_stat(box, "Deck", "%d cards" % (deck.cards.size() if deck != null else 0))
	box.add_child(ScreenUI.experience_bar(profile))
	# Crafting resources earned from runs (essences / King Pieces).
	for id: String in profile.materials.ids():
		var n := profile.materials.count(id)
		if n > 0:
			_add_stat(box, Materials.display_name(id), str(n))
	return panel


func _add_stat(box: VBoxContainer, key: String, value: String) -> void:
	var lbl := Label.new()
	lbl.text = "%s:  %s" % [key, value]
	lbl.add_theme_font_size_override("font_size", 24)
	box.add_child(lbl)


# A meta-progression button that expands to fill its share of the top row.
func _meta_button(label: String, scene_path: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.size_flags_horizontal = SIZE_EXPAND_FILL
	btn.size_flags_vertical = SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 34)
	if scene_path.is_empty():
		btn.disabled = true
		btn.tooltip_text = "Coming soon"
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
