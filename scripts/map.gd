class_name MapScreen
extends Control

const HUD_HEIGHT := 56.0
const NODE_SIZE := Vector2(72, 38)
const H_PAD := 80.0
const V_PAD := 48.0

var map_data: MapData
var current_node_id: int
var node_positions: Dictionary = {}
var encounter_rng: RandomNumberGenerator

# Registry of node-type -> handler. Adding a new node type with real
# gameplay is: write a NodeKind subclass, register it here, done — no other
# changes to this file needed. Types absent from this dict (Event, Shop,
# Rest today) are passed-through with no behaviour, same as before.
var _node_kinds: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

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
	call_deferred("_build_map")


func _build_hud() -> void:
	var hud := PanelContainer.new()
	hud.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
	hud.custom_minimum_size.y = HUD_HEIGHT
	add_child(hud)
	hud.add_child(RunHUD.new())


func _build_map() -> void:
	_calculate_positions()
	_rebuild_node_buttons()
	queue_redraw()

	var quit_btn := Button.new()
	quit_btn.text = "Save & Quit"
	quit_btn.add_theme_font_size_override("font_size", 13)
	quit_btn.anchor_left = 0.0
	quit_btn.anchor_top = 1.0
	quit_btn.anchor_right = 0.0
	quit_btn.anchor_bottom = 1.0
	quit_btn.offset_left = 16
	quit_btn.offset_top = -48
	quit_btn.offset_right = 130
	quit_btn.offset_bottom = -16
	quit_btn.pressed.connect(_on_quit_pressed)
	add_child(quit_btn)

	# Forge is a permanently available action, not a map node — combining
	# cards already costs two deck slots for one, so it doesn't need the
	# extra scarcity of being gated behind a rare node.
	var forge_btn := Button.new()
	forge_btn.text = "Forge"
	forge_btn.add_theme_font_size_override("font_size", 13)
	forge_btn.modulate = MapNodeData.get_color(MapNodeData.Type.FORGE)
	forge_btn.anchor_left = 1.0
	forge_btn.anchor_top = 1.0
	forge_btn.anchor_right = 1.0
	forge_btn.anchor_bottom = 1.0
	forge_btn.offset_left = -134
	forge_btn.offset_top = -48
	forge_btn.offset_right = -16
	forge_btn.offset_bottom = -16
	forge_btn.pressed.connect(func(): _node_kinds[MapNodeData.Type.FORGE].enter(null, self))
	add_child(forge_btn)


func _calculate_positions() -> void:
	var map_top: float = HUD_HEIGHT
	var usable_w: float = size.x - H_PAD * 2.0
	var usable_h: float = size.y - map_top - V_PAD * 2.0
	var floor_step: float = usable_h / float(MapData.FLOORS - 1)

	for floor_nodes: Array in map_data.floors:
		var count: int = floor_nodes.size()
		for i in count:
			var node: MapNodeData = floor_nodes[i]
			var x: float = size.x / 2.0 if count == 1 \
				else H_PAD + usable_w * float(i) / float(count - 1)
			var y: float = map_top + V_PAD + usable_h - float(node.floor) * floor_step
			node_positions[node.id] = Vector2(x, y)


func _rebuild_node_buttons() -> void:
	for child in get_children():
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
			btn.custom_minimum_size = NODE_SIZE
			btn.size = NODE_SIZE
			btn.position = pos - NODE_SIZE / 2.0

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

			add_child(btn)


func _draw() -> void:
	if node_positions.is_empty():
		return
	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			var from: Vector2 = node_positions.get(node.id, Vector2.ZERO)
			for next_id: int in node.connections:
				var to: Vector2 = node_positions.get(next_id, Vector2.ZERO)
				var col: Color = Color(0.7, 0.6, 0.25, 0.8) if node.visited \
					else Color(0.55, 0.55, 0.55, 0.4)
				draw_line(from, to, col, 2.0)


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
		queue_redraw()

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
