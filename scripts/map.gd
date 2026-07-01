class_name MapScreen
extends Control

const HUD_HEIGHT := 56.0
# Medallion diameter. Big in canvas units on purpose: canvas_items scales the 1920 design
# down onto the phone, so nodes need to be large to read/tap. The map scrolls, so size
# isn't space-constrained. The type caption and reward badge hang below the circle.
const NODE_DIAM := 62.0
const NODE_DIAM_COMPACT := 150.0
const V_PAD := 48.0

# --- Tunable in the Inspector (select the Map root node in map.tscn, drag the sliders,
# --- then run to see the result). Spacing is a multiple of node diameter, so it scales with
# --- node size. Lane spacing is still capped to the viewport width so nodes never clip.
@export_group("Node Spacing")
## Horizontal gap between lanes, ×node diameter (desktop).
@export_range(1.0, 6.0, 0.05) var lane_spacing_mult := 2.8
## Horizontal gap between lanes, ×node diameter (compact / phone).
@export_range(1.0, 6.0, 0.05) var lane_spacing_mult_compact := 1.9
## Vertical gap between floors, ×node diameter (desktop).
@export_range(1.0, 6.0, 0.05) var floor_spacing_mult := 2.6
## Vertical gap between floors, ×node diameter (compact / phone).
@export_range(1.0, 6.0, 0.05) var floor_spacing_mult_compact := 2.1
## Layout relaxation passes: nodes are repeatedly pulled toward the average position of the
## nodes they connect to (keeping each floor ordered + spaced), so connected nodes sit close
## and trails stay short. More passes = tighter to the branch structure. 0 = raw lane grid.
@export_range(0, 24, 1) var relax_passes := 10
## Optional organic sparsity ON TOP of the relaxed layout: each node nudged by up to this
## ×lane spacing (seeded per map, stable across reloads). 0 = clean relaxed layout.
@export_range(0.0, 0.4, 0.01) var organic_jitter := 0.0

@export_group("Trails")
## Trail bow, as a fraction of the edge's HORIZONTAL travel — so straight-up edges stay
## straight and only angled edges curve, more the more they lean. 0 = always straight.
@export_range(0.0, 0.8, 0.01) var trail_bow := 0.28
## Which way the trails bow: outward (away from the centre of the fork) vs inward.
@export var trail_curve_outward := true

@export_group("Node Variety")
## Anti-clustering: when a node type (Rest/Shop/Event — not Combat) is rolled, its weight
## immediately drops to this fraction, then climbs back to full over "Type Recovery" nodes.
## Lower = harsher penalty on back-to-back repeats. 1 = no penalty.
@export_range(0.0, 1.0, 0.05) var type_repeat_drop := 0.15
## How many generated nodes a just-rolled type takes to recover full weight. 0 = feature off.
@export_range(0, 12, 1) var type_recovery := 3
## Dot radius, ×node radius.
@export_range(0.02, 0.3, 0.005) var trail_dot_radius_mult := 0.085
## Gap between dots, ×node radius (smaller = denser trail).
@export_range(0.2, 1.5, 0.05) var trail_dot_spacing_mult := 0.5

@export_group("Forge Button")
## Forge button CENTRE as a fraction of the screen (0 = left/top, 1 = right/bottom). The map
## nodes sit in a centred band with empty side margins, so pull X in from 1.0 to bring the
## button nearer the content. Drag these in the Inspector, then run, to place it exactly.
@export_range(0.0, 1.0, 0.01) var forge_pos_x := 0.84
@export_range(0.0, 1.0, 0.01) var forge_pos_y := 0.5
## Forge button diameter, px (desktop / compact-phone).
@export_range(64.0, 240.0, 2.0) var forge_diam := 112.0
@export_range(80.0, 280.0, 2.0) var forge_diam_compact := 150.0

var map_data: MapData
var current_node_id: int
var node_positions: Dictionary = {}

# Registry of node-type -> handler. Adding a new node type with real
# gameplay is: write a NodeKind subclass, register it here, done — no other
# changes to this file needed. Types absent from this dict (Event, Shop,
# Rest today) are passed-through with no behaviour, same as before.
var _node_kinds: Dictionary = {}

var _scroll: ScrollContainer
var _canvas: MapCanvas
var _compact := false
var _node_diam := NODE_DIAM
var _hud_height := HUD_HEIGHT
var _bottom_bar_height := 56.0


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	_compact = UIScale.is_compact()
	_node_diam = NODE_DIAM_COMPACT if _compact else NODE_DIAM
	_hud_height = 104.0 if _compact else 68.0
	_bottom_bar_height = 140.0 if _compact else 96.0

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

	map_data = MapData.generate(GameData.current_map_state.map_seed, type_repeat_drop, type_recovery)
	current_node_id = GameData.current_map_state.current_node_id

	for vid in GameData.current_map_state.visited_nodes:
		var n: MapNodeData = map_data.get_node_by_id(vid)
		if n:
			n.visited = true

	# Dark themed backdrop (was raw engine gray) so the trails + medallions read on it and the
	# screen matches the rest of the game's chrome. Added first → sits behind everything.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = ScreenUI.BG_COLOR
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(bg)

	_build_hud()
	_build_scroll()
	_build_bottom_bar()
	_build_forge_fab()
	call_deferred("_build_map")

	# Hardware/browser back performs the same safe Save & Quit as the bottom bar (never quits the app).
	Nav.set_back(_on_quit_pressed)


func _build_hud() -> void:
	# The header comes from the shared system (ScreenUI.header_bar): the bar chrome, the docked ✕
	# (a redundant exit alongside the bottom Save & Quit — both save & return to the hub), and the
	# OS-back wiring are all handled there. This screen only fills the content slot with shared
	# widgets, and never renders any info a different way than other views do.
	var hb := ScreenUI.header_bar(_on_quit_pressed)
	hb.bar.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
	add_child(hb.bar)
	_hud_height = hb.bar.custom_minimum_size.y   # the scroll sits below the real header height

	# Each piece is a shared widget in its own chip. Content stacks LEFT (Act title · HP · Gold ·
	# Relics) then a flexible gap, then stacks RIGHT (EXP · ✕). Relics is the rightmost left-aligned
	# element, so the open middle space is its room to grow as relics are collected.
	var content: HBoxContainer = hb.content
	content.add_theme_constant_override("separation", 16 if _compact else 12)
	var run := GameData.current_run

	var act := Label.new()
	act.text = "Act %d" % run.act
	act.add_theme_font_size_override("font_size", 34 if _compact else 22)
	act.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	act.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	content.add_child(act)

	content.add_child(ScreenUI.stat("HP", "%d / %d" % [run.king_health(), run.king_max_health()], Color(0.62, 0.9, 0.66)))
	content.add_child(ScreenUI.stat("Gold", str(run.gold), Color(0.98, 0.85, 0.35)))
	content.add_child(ScreenUI.header_chip(RelicTray.new()))

	# Open space between the left stack and the right-aligned EXP — Relics grows into it.
	var gap := Control.new()
	gap.size_flags_horizontal = SIZE_EXPAND_FILL
	content.add_child(gap)

	if GameData.current_profile != null:
		content.add_child(ScreenUI.header_chip(ScreenUI.experience_bar_compact(GameData.current_profile, _compact, false)))


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
	var inset := int(UIScale.safe_inset())
	pad.add_theme_constant_override("margin_left", inset + 8)
	pad.add_theme_constant_override("margin_right", inset + 8)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	bar.add_child(pad)

	var hbox := HBoxContainer.new()
	pad.add_child(hbox)

	var font := 30 if _compact else 20
	var btn_size := Vector2(300, 96) if _compact else Vector2(210, 60)

	var quit_btn := Button.new()
	quit_btn.text = "Save & Quit"
	quit_btn.add_theme_font_size_override("font_size", font)
	quit_btn.custom_minimum_size = btn_size
	quit_btn.pressed.connect(_on_quit_pressed)
	hbox.add_child(quit_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Debug-only: jump to the free relic/charm acquisition screen to stress-test content.
	var debug_btn := Button.new()
	debug_btn.text = "Debug Items"
	debug_btn.add_theme_font_size_override("font_size", font)
	debug_btn.custom_minimum_size = btn_size
	debug_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/debug_shop.tscn"))
	hbox.add_child(debug_btn)
	# Forge moved out of this bar into a prominent floating button — see _build_forge_fab().


# A big chunky round Forge button (the one always-available action) floating over the
# lower-right of the MAP area — deliberately pulled in off the corner and up into the main
# content so it reads as a primary feature on its own, without glow/animation gimmicks.
func _build_forge_fab() -> void:
	var diam: float = forge_diam_compact if _compact else forge_diam
	var amber := MapNodeData.get_color(MapNodeData.Type.FORGE)

	var fab := Control.new()
	# Centre the button at (forge_pos_x, forge_pos_y) of the screen — tune in the Inspector.
	fab.anchor_left = forge_pos_x; fab.anchor_right = forge_pos_x
	fab.anchor_top  = forge_pos_y; fab.anchor_bottom = forge_pos_y
	fab.offset_left = -diam * 0.5; fab.offset_right  = diam * 0.5
	fab.offset_top  = -diam * 0.5; fab.offset_bottom = diam * 0.5
	fab.z_index = 50
	add_child(fab)

	var btn := Button.new()
	btn.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "Forge — combine two cards into one"
	_style_forge_button(btn, amber, diam)
	btn.pressed.connect(func(): _node_kinds[MapNodeData.Type.FORGE].enter(null, self))
	fab.add_child(btn)

	# Anvil icon centred inside the circle (clicks pass through to the button).
	var icon := TextureRect.new()
	icon.texture = MapNodeData.get_icon(MapNodeData.Type.FORGE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE     # let it shrink to the circle
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var pad := diam * 0.24
	icon.offset_left = pad; icon.offset_top = pad
	icon.offset_right = -pad; icon.offset_bottom = -pad
	fab.add_child(icon)


func _style_forge_button(btn: Button, amber: Color, diam: float) -> void:
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		var bg := amber
		if state == "hover":   bg = amber.lightened(0.18)
		if state == "pressed": bg = amber.darkened(0.15)
		sb.bg_color = bg
		sb.set_corner_radius_all(int(diam))          # > radius/2 → clamps to a full circle
		sb.border_color = Color(1.0, 0.93, 0.72)     # bright rim
		sb.set_border_width_all(5)
		sb.shadow_color = Color(0.0, 0.0, 0.0, 0.35)  # soft drop shadow for depth (no glow halo)
		sb.shadow_size = 6
		sb.shadow_offset = Vector2(0, 3)
		sb.anti_aliasing = true
		btn.add_theme_stylebox_override(state, sb)


func _build_map() -> void:
	# Canvas width fits the scroll viewport (no horizontal scroll); its height is whatever the
	# fixed floor spacing needs (always taller than the viewport, so it scrolls).
	var view: Vector2 = _scroll.size
	if view.x <= 0.0:
		view = Vector2(size.x, size.y - _hud_height - _bottom_bar_height)

	var floor_spacing: float = _node_diam * (floor_spacing_mult_compact if _compact else floor_spacing_mult)
	var canvas_h: float = maxf(view.y, V_PAD * 2.0 + floor_spacing * float(MapData.FLOORS - 1))
	_canvas.custom_minimum_size = Vector2(0, canvas_h)

	_calculate_positions(Vector2(view.x, canvas_h), floor_spacing)
	_canvas.positions = node_positions
	_canvas.map_data = map_data
	_canvas.node_radius = _node_diam * 0.5
	_canvas.curve_bow = trail_bow
	_canvas.curve_dir = -1.0 if trail_curve_outward else 1.0
	_canvas.dot_radius_mult = trail_dot_radius_mult
	_canvas.dot_spacing_mult = trail_dot_spacing_mult
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


# Node x-positions follow the BRANCHING, not the abstract lane index: starting from the lane
# grid, each node is relaxed toward the average x of the nodes it connects to, so connected
# nodes sit close and trails stay short instead of stretching across the map. Each floor's
# nodes are kept in lane order with a minimum gap (so paths never cross or overlap). y comes
# straight from the floor. The result is then fit-to-width and centred.
func _calculate_positions(canvas_size: Vector2, floor_spacing: float) -> void:
	var lane_mult: float = lane_spacing_mult_compact if _compact else lane_spacing_mult
	var lane_spacing: float = _node_diam * lane_mult
	var min_gap: float = lane_spacing

	# Neighbours in both directions (parents + children), so relaxation pulls a node toward
	# everything it's wired to.
	var nbrs: Dictionary = {}
	var x_of: Dictionary = {}
	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			nbrs[node.id] = []
			x_of[node.id] = float(node.column) * lane_spacing
	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			for c: int in node.connections:
				nbrs[node.id].append(c)
				nbrs[c].append(node.id)

	for pass_i in relax_passes:
		# Pull each node toward the mean of itself + its neighbours.
		var next_x: Dictionary = {}
		for id: int in x_of:
			var sum: float = x_of[id]
			var count: float = 1.0
			for nb: int in nbrs[id]:
				sum += x_of[nb]
				count += 1.0
			next_x[id] = sum / count
		x_of = next_x
		# Re-impose lane order + min gap per floor. Alternate sweep direction so the floors
		# don't all drift one way.
		for floor_nodes: Array in map_data.floors:
			var ordered: Array = floor_nodes.duplicate()
			ordered.sort_custom(func(a: MapNodeData, b: MapNodeData) -> bool: return a.column < b.column)
			if pass_i % 2 == 0:
				for i in range(1, ordered.size()):
					var lo: float = x_of[ordered[i - 1].id] + min_gap
					if x_of[ordered[i].id] < lo:
						x_of[ordered[i].id] = lo
			else:
				for i in range(ordered.size() - 2, -1, -1):
					var hi: float = x_of[ordered[i + 1].id] - min_gap
					if x_of[ordered[i].id] > hi:
						x_of[ordered[i].id] = hi

	_finalize_positions(canvas_size, floor_spacing, x_of, lane_spacing)


# Fit the relaxed x-coordinates into the viewport width (shrink only if too wide), centre
# them, add optional organic jitter, and pair with the floor y.
func _finalize_positions(canvas_size: Vector2, floor_spacing: float, x_of: Dictionary, lane_spacing: float) -> void:
	var min_x: float = INF
	var max_x: float = -INF
	for id: int in x_of:
		min_x = minf(min_x, x_of[id])
		max_x = maxf(max_x, x_of[id])
	var span: float = maxf(max_x - min_x, 1.0)
	var avail: float = canvas_size.x - _node_diam - 16.0
	var scale: float = minf(1.0, avail / span)
	var graph_center: float = (min_x + max_x) * 0.5
	var canvas_center: float = canvas_size.x * 0.5
	var usable_h: float = canvas_size.y - V_PAD * 2.0
	var half: float = _node_diam * 0.5
	var jitter := RandomNumberGenerator.new()

	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			var x: float = canvas_center + (x_of[node.id] - graph_center) * scale
			var y: float = V_PAD + usable_h - float(node.floor) * floor_spacing
			if organic_jitter > 0.0:
				jitter.seed = GameData.current_map_state.map_seed ^ (node.id * 2654435761)
				x += jitter.randf_range(-1.0, 1.0) * lane_spacing * organic_jitter
				y += jitter.randf_range(-1.0, 1.0) * floor_spacing * organic_jitter * 0.5
			x = clampf(x, half + 4.0, canvas_size.x - half - 4.0)
			node_positions[node.id] = Vector2(x, y)


func _rebuild_node_buttons() -> void:
	for child in _canvas.get_children():
		if child.get_meta("map_node", false):
			child.queue_free()

	var reachable: Array = map_data.get_reachable_nodes(current_node_id)
	var reachable_ids: Array = reachable.map(func(n: MapNodeData) -> int: return n.id)

	# Let the canvas highlight the edges leaving the current node (the branch choices).
	_canvas.current_id = current_node_id
	_canvas.reachable_ids = reachable_ids

	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			var pos: Vector2 = node_positions[node.id]
			var is_current: bool = node.id == current_node_id
			var is_reachable: bool = node.id in reachable_ids

			var state: int
			if is_current:
				state = MapNodeMedallion.State.CURRENT
			elif node.visited:
				state = MapNodeMedallion.State.VISITED
			elif is_reachable:
				state = MapNodeMedallion.State.REACHABLE
			else:
				state = MapNodeMedallion.State.LOCKED

			var caption := ""
			if node.type == MapNodeData.Type.BOSS and GameData.current_run.act >= MapData.STAGES:
				caption = "Final Boss"

			var reward_summary := ""
			var reward_color := Color(0.8, 0.82, 0.9)
			if not node.material_rewards.is_empty():
				reward_summary = Materials.summary(node.material_rewards)
				# Single-element rewards tint by their element; mixed rewards stay neutral.
				if node.material_rewards.size() == 1:
					reward_color = Materials.color(node.material_rewards.keys()[0])

			var med := MapNodeMedallion.new()
			med.set_meta("map_node", true)
			med.configure(node.type, state, _node_diam, _compact, caption, reward_summary, reward_color)
			med.position = pos - Vector2(_node_diam, _node_diam) / 2.0
			if not reward_summary.is_empty():
				var label := caption if not caption.is_empty() else MapNodeData.get_label(node.type)
				med.tooltip_text = "%s — reward: %s" % [label, reward_summary]
			if is_reachable:
				var captured: MapNodeData = node
				med.pressed.connect(func(): _on_node_selected(captured))
			_canvas.add_child(med)


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
