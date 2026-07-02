extends Control

# The Upgrades screen (hub's "Upgrades" button): authored skill trees the player will spend
# points in to customise their profile. Trees come from data/upgrades/*.json via UpgradeTree.
# This is the presentation shell only — a tab per tree, the selected tree's node graph in a
# scroll area, and a detail strip previewing the focused tree/node. The spend/effect
# mechanics are intentionally NOT wired yet (TBD): nodes are preview-only here.

var _compact := false
var _tree_view: UpgradeTreeView
var _tabs: HFlowContainer
var _detail_title: Label
var _detail_body: Label
var _buy_btn: Button
var _exp_pad: MarginContainer
var _tab_buttons: Dictionary = {}    # tree id -> Button
var _selected_tree_id := ""
var _selected_node: UpgradeNode = null


func _ready() -> void:
	# Reached without a selected save (e.g. a stale direct load) — bounce to save select.
	if GameData.current_profile == null or GameData.current_slot < 0:
		Nav.goto.call_deferred("res://scenes/game_slots.tscn")
		return
	# Rebuild if the form factor flips (e.g. previewing mobile by resizing in the editor).
	UIScale.layout_changed.connect(func(): get_tree().reload_current_scene(), CONNECT_ONE_SHOT)
	_compact = UIScale.is_compact()

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	_build_body(root)

	var trees := UpgradeTree.all()
	if trees.is_empty():
		_detail_title.text = "No upgrades authored yet"
		_detail_body.text = "Add skill trees in data/upgrades/*.json and they'll appear here."
		return
	for tree: UpgradeTree in trees:
		_tabs.add_child(_make_tab(tree))
	_select_tree(trees[0].id)


func get_chrome() -> Dictionary:
	return {"title": "Upgrades", "exit": func(): Nav.goto("res://scenes/game_world.tscn"),
		"show_footer": true}


func _build_body(root: Control) -> void:
	# Experience / upgrade-point banner — this is where points are spent, so show the balance.
	_exp_pad = MarginContainer.new()
	for side in ["left", "right", "top"]:
		_exp_pad.add_theme_constant_override("margin_" + side, 20 if _compact else 16)
	_exp_pad.add_child(ScreenUI.experience_bar(GameData.current_profile, _compact))
	root.add_child(_exp_pad)

	# Tab strip — one button per tree; wraps so it works on narrow/compact screens.
	_tabs = HFlowContainer.new()
	_tabs.add_theme_constant_override("h_separation", 10)
	_tabs.add_theme_constant_override("v_separation", 8)
	var tabs_margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		tabs_margin.add_theme_constant_override("margin_" + side, 16 if _compact else 12)
	tabs_margin.add_child(_tabs)
	root.add_child(tabs_margin)

	# Tree graph — scrolls in both axes when a tree is larger than the viewport.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	root.add_child(scroll)
	_tree_view = UpgradeTreeView.new().setup(_compact)
	_tree_view.size_flags_horizontal = SIZE_EXPAND_FILL
	_tree_view.size_flags_vertical = SIZE_EXPAND_FILL
	_tree_view.node_selected.connect(_on_node_selected)
	scroll.add_child(_tree_view)

	# Detail strip — previews the focused tree, then whichever node is clicked.
	var detail := PanelContainer.new()
	detail.custom_minimum_size.y = 168.0 if _compact else 132.0
	var detail_style := StyleBoxFlat.new()
	detail_style.bg_color = ScreenUI.SURFACE_COLOR
	detail_style.border_color = ScreenUI.SURFACE_BORDER
	detail_style.set_border_width_all(2)
	detail_style.set_corner_radius_all(10)
	detail_style.set_content_margin_all(0)
	detail.add_theme_stylebox_override("panel", detail_style)
	root.add_child(detail)
	var dbox := VBoxContainer.new()
	dbox.add_theme_constant_override("separation", 4)
	var dpad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		dpad.add_theme_constant_override("margin_" + side, 18 if _compact else 14)
	dpad.add_child(dbox)
	detail.add_child(dpad)

	# Header row: the focused node's title on the left, its purchase button on the right.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	dbox.add_child(head)

	_detail_title = Label.new()
	_detail_title.add_theme_font_size_override("font_size", 26 if _compact else 20)
	_detail_title.size_flags_horizontal = SIZE_EXPAND_FILL
	_detail_title.size_flags_vertical = SIZE_SHRINK_CENTER
	head.add_child(_detail_title)

	_buy_btn = ScreenUI.action_button("", _on_buy_pressed,
		Vector2(260, 96) if _compact else Vector2(200, 64), 26 if _compact else 20,
		ScreenUI.CHROME_CONFIRM)
	_buy_btn.visible = false
	head.add_child(_buy_btn)

	_detail_body = Label.new()
	_detail_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_body.add_theme_font_size_override("font_size", 19 if _compact else 14)
	_detail_body.size_flags_vertical = SIZE_EXPAND_FILL
	dbox.add_child(_detail_body)


func _make_tab(tree: UpgradeTree) -> Button:
	var btn := ScreenUI.action_button(tree.display_name, func() -> void: _select_tree(tree.id),
		Vector2(0, 72) if _compact else Vector2.ZERO, 24 if _compact else 16,
		ScreenUI.CHROME_NEUTRAL)
	btn.toggle_mode = true
	_tab_buttons[tree.id] = btn
	return btn


func _select_tree(tree_id: String) -> void:
	_selected_tree_id = tree_id
	_selected_node = null
	var tree := UpgradeTree.get_tree_def(tree_id)
	for tid: String in _tab_buttons:
		var btn: Button = _tab_buttons[tid]
		btn.button_pressed = tid == tree_id
		btn.disabled = tid == tree_id   # the active tab reads as selected and isn't re-clickable
	_tree_view.show_tree(tree)
	_buy_btn.visible = false
	if tree != null:
		_detail_title.text = tree.display_name
		_detail_body.text = tree.description


func _on_node_selected(node: UpgradeNode) -> void:
	_selected_node = node
	_detail_title.text = "%s   ·   Cost %d" % [node.display_name, node.cost]
	_detail_body.text = node.description
	_refresh_buy_btn()


# Reflects whether the focused node is owned / buyable / locked / unaffordable on the button.
func _refresh_buy_btn() -> void:
	if _selected_node == null:
		_buy_btn.visible = false
		return
	var profile := GameData.current_profile
	_buy_btn.visible = true
	if profile.owns_upgrade(_selected_node.id):
		_buy_btn.text = "Owned"
		_buy_btn.disabled = true
	elif not profile.upgrade_unlocked(_selected_node):
		_buy_btn.text = "Locked"
		_buy_btn.disabled = true
	elif profile.upgrade_points < _selected_node.cost:
		_buy_btn.text = "Need %d points" % _selected_node.cost
		_buy_btn.disabled = true
	else:
		_buy_btn.text = "Purchase  (%d)" % _selected_node.cost
		_buy_btn.disabled = false


func _on_buy_pressed() -> void:
	if _selected_node == null or not GameData.current_profile.purchase_upgrade(_selected_node):
		return
	GameData.save_profile()
	GameData.rebuild_modifiers()   # the purchase takes effect on the next run immediately
	_tree_view.refresh_states()
	_refresh_buy_btn()
	_refresh_exp_bar()


# Rebuilds the experience/points banner so the spent points show immediately.
func _refresh_exp_bar() -> void:
	for c in _exp_pad.get_children():
		c.queue_free()
	_exp_pad.add_child(ScreenUI.experience_bar(GameData.current_profile, _compact))
