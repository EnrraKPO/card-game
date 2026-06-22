class_name MapScreen
extends Control

const HUD_HEIGHT := 56.0
const NODE_SIZE := Vector2(72, 38)
# Big in canvas units on purpose: canvas_items scales the 1920 design down onto the phone,
# so these need to be large to read/tap. The map scrolls, so size isn't space-constrained.
const NODE_SIZE_COMPACT := Vector2(230, 104)
const H_PAD := 80.0
const V_PAD := 48.0
# Vertical spacing between floors on compact: large enough that the map overflows the
# screen and scrolls, with big tappable nodes that don't collide with reward captions.
const COMPACT_FLOOR_STEP := 270.0

var map_data: MapData
var current_node_id: int
var node_positions: Dictionary = {}
var encounter_rng: RandomNumberGenerator

# Registry of node-type -> handler. Adding a new node type with real
# gameplay is: write a NodeKind subclass, register it here, done — no other
# changes to this file needed. Types absent from this dict (Event, Shop,
# Rest today) are passed-through with no behaviour, same as before.
var _node_kinds: Dictionary = {}

var _scroll: ScrollContainer
var _canvas: MapCanvas
var _compact := false
var _node_size := NODE_SIZE
var _hud_height := HUD_HEIGHT
var _bottom_bar_height := 56.0


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	_compact = UIScale.is_compact()
	_node_size = NODE_SIZE_COMPACT if _compact else NODE_SIZE
	_hud_height = 92.0 if _compact else HUD_HEIGHT
	_bottom_bar_height = 124.0 if _compact else 56.0

	_node_kinds = {
		MapNodeData.Type.COMBAT: NodeKindCombat.new(),
		MapNodeData.Type.ELITE:  NodeKindCombat.new(),
		MapNodeData.Type.BOSS:   NodeKindCombat.new(),
		MapNodeData.Type.FORGE:  NodeKindForge.new(),
		MapNodeData.Type.SHOP:   NodeKindShop.new(),
		MapNodeData.Type.REST:   NodeKindRest.new(),
		MapNodeData.Type.EVENT:  NodeKindEvent.new(),
	}

	if GameData.current_encounter != null:
		_process_combat_return()

	# Multi-stage: standing on the boss node means this stage is cleared. Route to the
	# Stage Cleared screen (which hands out the special reward and then advances), or to
	# Run Successful on the final stage. The map itself never advances — those screens do,
	# so the flow is identical whether we arrived from combat or a reload.
	if _stage_cleared():
		var screen := "run_success" if GameData.current_run.act >= MapData.STAGES else "stage_cleared"
		get_tree().change_scene_to_file.call_deferred("res://scenes/%s.tscn" % screen)
		return

	map_data = MapData.generate(GameData.current_map_state.map_seed)
	current_node_id = GameData.current_map_state.current_node_id

	encounter_rng = RandomNumberGenerator.new()
	encounter_rng.seed = GameData.current_map_state.map_seed

	for vid in GameData.current_map_state.visited_nodes:
		var n: MapNodeData = map_data.get_node_by_id(vid)
		if n:
			n.visited = true

	_build_hud()
	_build_scroll()
	_build_bottom_bar()
	call_deferred("_build_map")

	# Hardware/browser back performs the same safe Save & Quit as the bottom bar (never quits the app).
	Nav.set_back(_on_quit_pressed)


func _build_hud() -> void:
	var hud := PanelContainer.new()
	hud.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
	hud.custom_minimum_size.y = _hud_height
	add_child(hud)

	# Single row: RunHUD (HP/Act/Gold) stretches; the relic strip sits at the right (tap to discard).
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	hud.add_child(row)

	var run_hud := RunHUD.new()
	run_hud.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(run_hud)
	row.add_child(RelicTray.new())


# The scrollable map area, filling the screen below the HUD. The canvas inside it carries
# the nodes + connection lines; on compact it's taller than the viewport so it scrolls.
func _build_scroll() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_scroll.offset_top = _hud_height
	_scroll.offset_bottom = -_bottom_bar_height   # leave room for the bottom action bar
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_canvas = MapCanvas.new()
	_scroll.add_child(_canvas)


# Forge + Save & Quit live in their own bottom bar, separate from the scrollable map so
# they never overlap nodes.
func _build_bottom_bar() -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
	bar.offset_top = -_bottom_bar_height
	add_child(bar)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_right", 16)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	bar.add_child(pad)

	var hbox := HBoxContainer.new()
	pad.add_child(hbox)

	var font := 32 if _compact else 14
	var btn_size := Vector2(300, 84) if _compact else Vector2(130, 0)

	var quit_btn := Button.new()
	quit_btn.text = "Save & Quit"
	quit_btn.add_theme_font_size_override("font_size", font)
	quit_btn.custom_minimum_size = btn_size
	quit_btn.pressed.connect(_on_quit_pressed)
	hbox.add_child(quit_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Forge is a permanently available action, not a map node — combining cards already
	# costs two deck slots for one, so it doesn't need the scarcity of a rare node.
	var forge_btn := Button.new()
	forge_btn.text = "Forge"
	forge_btn.add_theme_font_size_override("font_size", font)
	forge_btn.modulate = MapNodeData.get_color(MapNodeData.Type.FORGE)
	forge_btn.custom_minimum_size = btn_size
	forge_btn.pressed.connect(func(): _node_kinds[MapNodeData.Type.FORGE].enter(null, self))
	hbox.add_child(forge_btn)


func _build_map() -> void:
	# Canvas width fits the scroll viewport (no horizontal scroll); height fills it on
	# desktop, or grows tall enough to scroll through every floor on compact.
	var view: Vector2 = _scroll.size
	if view.x <= 0.0:
		view = Vector2(size.x, size.y - _hud_height - _bottom_bar_height)
	var canvas_h: float = view.y
	if _compact:
		canvas_h = maxf(view.y, V_PAD * 2.0 + COMPACT_FLOOR_STEP * float(MapData.FLOORS - 1))
	_canvas.custom_minimum_size = Vector2(0, canvas_h)

	_calculate_positions(Vector2(view.x, canvas_h))
	_canvas.positions = node_positions
	_canvas.map_data = map_data
	_canvas.line_width = 4.0 if _compact else 2.0
	_rebuild_node_buttons()
	_canvas.queue_redraw()

	call_deferred("_scroll_to_current")


# Centre the scroll on the player's current node (or the start floor at the bottom for a
# fresh map), so they're not staring at the far end of the path on a tall compact map.
func _scroll_to_current() -> void:
	if _scroll == null:
		return
	var target_y: float
	if current_node_id >= 0 and node_positions.has(current_node_id):
		target_y = node_positions[current_node_id].y - _scroll.size.y / 2.0
	else:
		target_y = _canvas.size.y   # start floor sits at the bottom of the canvas
	_scroll.scroll_vertical = int(maxf(0.0, target_y))


func _calculate_positions(canvas_size: Vector2) -> void:
	var usable_w: float = canvas_size.x - H_PAD * 2.0
	var usable_h: float = canvas_size.y - V_PAD * 2.0
	var floor_step: float = usable_h / float(MapData.FLOORS - 1)

	for floor_nodes: Array in map_data.floors:
		var count: int = floor_nodes.size()
		for i in count:
			var node: MapNodeData = floor_nodes[i]
			var x: float = canvas_size.x / 2.0 if count == 1 \
				else H_PAD + usable_w * float(i) / float(count - 1)
			var y: float = V_PAD + usable_h - float(node.floor) * floor_step
			node_positions[node.id] = Vector2(x, y)


func _rebuild_node_buttons() -> void:
	for child in _canvas.get_children():
		if child.get_meta("map_node", false):
			child.queue_free()

	var reachable: Array = map_data.get_reachable_nodes(current_node_id)
	var reachable_ids: Array = reachable.map(func(n: MapNodeData) -> int: return n.id)

	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			var pos: Vector2 = node_positions[node.id]
			var btn := Button.new()
			btn.set_meta("map_node", true)
			btn.text = MapNodeData.get_label(node.type)
			if node.type == MapNodeData.Type.BOSS and GameData.current_run.act >= MapData.STAGES:
				btn.text = "Final Boss"
			if _compact:
				btn.add_theme_font_size_override("font_size", 38)
			btn.custom_minimum_size = _node_size
			btn.size = _node_size
			btn.position = pos - _node_size / 2.0

			var is_current: bool = node.id == current_node_id
			var is_reachable: bool = node.id in reachable_ids

			if is_current:
				btn.modulate = Color(1.0, 0.95, 0.2)
			elif node.visited:
				btn.modulate = Color(0.3, 0.3, 0.3)
				btn.disabled = true
			elif is_reachable:
				btn.modulate = MapNodeData.get_color(node.type)
			else:
				btn.modulate = Color(0.22, 0.22, 0.22, 0.8)
				btn.disabled = true

			if is_reachable:
				var captured: MapNodeData = node
				btn.pressed.connect(func(): _on_node_selected(captured))

			_canvas.add_child(btn)

			# Previewed resource reward, so routes can be planned at a glance.
			if not node.material_rewards.is_empty():
				btn.tooltip_text = "%s — reward: %s" % [btn.text, Materials.summary(node.material_rewards)]
				_add_reward_preview(node, pos)


# A small element-coloured "+2 Fire" caption under a node, showing its essence reward.
func _add_reward_preview(node: MapNodeData, center: Vector2) -> void:
	var lbl := Label.new()
	lbl.set_meta("map_node", true)
	lbl.text = Materials.summary(node.material_rewards)
	lbl.add_theme_font_size_override("font_size", 32 if _compact else 11)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var w := 280.0 if _compact else 100.0
	var lh := 38.0 if _compact else 14.0
	lbl.custom_minimum_size = Vector2(w, lh)
	lbl.size = Vector2(w, lh)
	lbl.position = center + Vector2(-w / 2.0, _node_size.y / 2.0 + 4.0)
	lbl.mouse_filter = MOUSE_FILTER_IGNORE
	# Single-element rewards tint by their element; mixed rewards stay neutral.
	var color := Color(0.8, 0.82, 0.9)
	if node.material_rewards.size() == 1:
		color = Materials.color(node.material_rewards.keys()[0])
	lbl.modulate = color if not node.visited else color.darkened(0.5)
	_canvas.add_child(lbl)


func _on_node_selected(node: MapNodeData) -> void:
	var is_combat := node.type in [
		MapNodeData.Type.COMBAT, MapNodeData.Type.ELITE, MapNodeData.Type.BOSS
	]

	if not is_combat:
		# Non-combat nodes (forge, etc.): advance map state immediately.
		if current_node_id >= 0:
			var prev: MapNodeData = map_data.get_node_by_id(current_node_id)
			if prev:
				prev.visited = true
				if current_node_id not in GameData.current_map_state.visited_nodes:
					GameData.current_map_state.visited_nodes.append(current_node_id)
		current_node_id = node.id
		GameData.current_map_state.current_node_id = current_node_id
		GameData.save_run()
		_rebuild_node_buttons()
		_canvas.queue_redraw()

	_resolve_node(node)


func _resolve_node(node: MapNodeData) -> void:
	if node.type in _node_kinds:
		_node_kinds[node.type].enter(node, self)


# True once the player is standing on the boss node — combat moves you onto a node
# only after winning it, so this means the stage's boss has been defeated.
func _stage_cleared() -> bool:
	return GameData.current_map_state.current_node_id == MapData.boss_node_id()


func _process_combat_return() -> void:
	# Reached only if the map loads while an encounter is still in memory
	# (e.g. mid-combat app crash). Clear it so the node stays clickable.
	GameData.current_encounter = null


func _on_quit_pressed() -> void:
	GameData.save_run()
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")
