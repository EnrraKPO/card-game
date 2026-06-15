extends Control

const HUD_HEIGHT := 56.0
const NODE_SIZE := Vector2(72, 38)
const H_PAD := 80.0
const V_PAD := 48.0

var map_data: MapData
var current_node_id: int
var node_positions: Dictionary = {}
var _node_resolvers: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	_node_resolvers = {
		MapNodeData.Type.COMBAT: _enter_combat,
		MapNodeData.Type.ELITE:  _enter_combat,
		MapNodeData.Type.BOSS:   _enter_combat,
		MapNodeData.Type.FORGE:  _enter_forge,
	}

	if GameData.current_encounter != null:
		_process_combat_return()

	map_data = MapData.generate(GameData.current_map_state.map_seed)
	current_node_id = GameData.current_map_state.current_node_id

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

	var dbg_forge := Button.new()
	dbg_forge.text = "[debug] forge"
	dbg_forge.add_theme_font_size_override("font_size", 13)
	dbg_forge.modulate = Color(1.0, 0.65, 0.1)
	dbg_forge.anchor_left = 0.0
	dbg_forge.anchor_top = 1.0
	dbg_forge.anchor_right = 0.0
	dbg_forge.anchor_bottom = 1.0
	dbg_forge.offset_left = 146
	dbg_forge.offset_top = -48
	dbg_forge.offset_right = 280
	dbg_forge.offset_bottom = -16
	dbg_forge.pressed.connect(func(): _enter_forge(null))
	add_child(dbg_forge)


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
	if node.type in _node_resolvers:
		_node_resolvers[node.type].call(node)


func _enter_combat(node: MapNodeData) -> void:
	GameData.current_encounter = _build_encounter(node.type)
	get_tree().change_scene_to_file("res://scenes/combat.tscn")


func _enter_forge(_node: MapNodeData) -> void:
	get_tree().change_scene_to_file("res://scenes/combination_screen.tscn")


func _process_combat_return() -> void:
	# Reward presentation will be added with the run system
	GameData.current_encounter = null


func _build_encounter(type: MapNodeData.Type) -> EncounterData:
	var enc := EncounterData.new()
	match type:
		MapNodeData.Type.COMBAT:
			enc.type = EncounterData.Type.COMBAT
			enc.enemy_deck = ["pawn", "pawn", "pawn", "bishop", "fire", "fire", "water", "earth"]
		MapNodeData.Type.ELITE:
			enc.type = EncounterData.Type.ELITE
			enc.enemy_deck = ["knight", "knight", "rook", "bishop", "bishop", "darkness", "darkness", "fire", "air"]
		MapNodeData.Type.BOSS:
			enc.type = EncounterData.Type.BOSS
			enc.enemy_deck = ["queen", "queen", "rook", "rook", "knight", "knight", "darkness", "darkness", "fire", "air"]
	enc.reward_pool = _generate_reward_pool()
	return enc


func _generate_reward_pool() -> Array[String]:
	var non_kings: Array[String] = []
	for card: CardData in CardData.all():
		if not card.is_king:
			non_kings.append(card.id)
	non_kings.shuffle()
	return non_kings.slice(0, mini(3, non_kings.size()))


func _on_quit_pressed() -> void:
	GameData.save_run()
	get_tree().change_scene_to_file("res://scenes/hello_screen.tscn")
