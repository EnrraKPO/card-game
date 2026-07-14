class_name MapScreen
extends Control

# Medallion diameter. Big in canvas units on purpose: canvas_items scales the 1920 design
# down onto the phone, so nodes need to be large to read/tap. The map scrolls, so size
# isn't space-constrained. The type caption and reward badge hang below the circle.
const NODE_DIAM := 84.0
const NODE_DIAM_COMPACT := 150.0
const V_PAD_TOP := 56.0
# Extra air under the bottom floor: the caption + reward badge hang BELOW the node circle,
# so the last row needs clearance or its text sits right on the screen edge. _build_map adds
# a node diameter on top of this so it scales with zoom.
const V_PAD_BOTTOM := 72.0

# Zoom level is remembered across map visits within the session (combat → map → combat).
static var _zoom_level := 1.0

# The always-available Forge action's button art (a complete circular glossy button — see
# _build_forge_fab, which shows this directly instead of drawing its own circle + anvil).
const FORGE_FAB_TEX := preload("res://assets/buttons/forge.png")

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
@export_range(0.02, 0.3, 0.005) var trail_dot_radius_mult := 0.11
## Gap between dots, ×node radius (smaller = denser trail).
@export_range(0.2, 1.5, 0.05) var trail_dot_spacing_mult := 0.42

@export_group("Zoom")
## Zoom slider range. 1.0 = the design-size layout; above it the canvas grows and pans.
@export_range(0.5, 1.0, 0.05) var zoom_min := 0.8
@export_range(1.0, 2.5, 0.05) var zoom_max := 1.8

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


func get_chrome() -> Dictionary:
	return {"fields": [ScreenUI.Field.ACT, ScreenUI.Field.HP, ScreenUI.Field.GOLD,
			ScreenUI.Field.RELICS, ScreenUI.Field.EXP], "exit": _on_quit_pressed,
		"show_footer": true, "inset": false, "footer_actions": [
			{"label": "Save & Quit", "action": _on_quit_pressed},
			{"label": "Debug Items", "action": func(): Nav.goto("res://scenes/debug_shop.tscn"),
				"align": "right"},
		]}


func _ready() -> void:
	_compact = UIScale.is_compact()
	_node_diam = _base_diam() * _zoom_level

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
		Nav.goto.call_deferred("res://scenes/%s.tscn" % screen)
		return

	map_data = MapData.generate(GameData.current_map_state.map_seed, type_repeat_drop, type_recovery)
	current_node_id = GameData.current_map_state.current_node_id

	for vid in GameData.current_map_state.visited_nodes:
		var n: MapNodeData = map_data.get_node_by_id(vid)
		if n:
			n.visited = true

	_build_scroll()
	_build_forge_fab()
	_build_zoom_slider()
	call_deferred("_build_map")


func _base_diam() -> float:
	return NODE_DIAM_COMPACT if _compact else NODE_DIAM


# The scrollable map area, filling the screen below the shared header and above the shared footer
# (Shell already reserved both, laying this content out in its own VBoxContainer row — nothing
# here needs to account for their heights). The canvas inside it carries the nodes + connection
# lines; on compact it's taller than the viewport so it scrolls.
func _build_scroll() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# Horizontal scroll appears only when zoomed in (the canvas grows wider than the view).
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(_scroll)

	_canvas = MapCanvas.new()
	_scroll.add_child(_canvas)


# A big chunky round Forge button (the one always-available action) floating over the
# lower-right of the MAP area — deliberately pulled in off the corner and up into the main
# content so it reads as a primary feature on its own, without glow/animation gimmicks.
func _build_forge_fab() -> void:
	var diam: float = forge_diam_compact if _compact else forge_diam

	var fab := Control.new()
	# Centre the button at (forge_pos_x, forge_pos_y) of the screen — tune in the Inspector.
	fab.anchor_left = forge_pos_x; fab.anchor_right = forge_pos_x
	fab.anchor_top  = forge_pos_y; fab.anchor_bottom = forge_pos_y
	fab.offset_left = -diam * 0.5; fab.offset_right  = diam * 0.5
	fab.offset_top  = -diam * 0.5; fab.offset_bottom = diam * 0.5
	fab.z_index = 50
	add_child(fab)

	# The provided circular button art IS the button face (glossy circle + anvil baked in), so we
	# just show it and lay a transparent Button over it for the click + tooltip.
	var tex := TextureRect.new()
	tex.texture = FORGE_FAB_TEX
	tex.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fab.add_child(tex)

	var btn := Button.new()
	btn.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "Forge — combine two cards into one"
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	btn.pressed.connect(func(): _node_kinds[MapNodeData.Type.FORGE].enter(null, self))
	# Tactile feedback on the art itself (the button has no visual of its own): brighten on hover,
	# sink darker on press.
	btn.mouse_entered.connect(func() -> void: if not btn.button_pressed: tex.modulate = Color(1.12, 1.12, 1.12))
	btn.mouse_exited.connect(func() -> void: tex.modulate = Color.WHITE)
	btn.button_down.connect(func() -> void: tex.modulate = Color(0.85, 0.85, 0.85))
	btn.button_up.connect(func() -> void: tex.modulate = Color.WHITE)
	fab.add_child(btn)


# A chunky vertical zoom slider (+ on top, − below, map-app style) floating over the left
# edge of the map area, vertically centred — the one region that stays clear of map content
# on both desktop (empty side margins) and compact (node rows hug the top/bottom corners).
# Dragging it rebuilds the map live at the new node scale (spacing is a multiple of node
# diameter, so the whole layout grows with it and the canvas pans/scrolls).
func _build_zoom_slider() -> void:
	# A translucent rounded panel behind the controls, so the slider reads as a UI control
	# sitting over the map rather than loose parts mixed into the nodes.
	var panel := PanelContainer.new()
	panel.z_index = 60
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT,
			Control.PRESET_MODE_MINSIZE, 32 if _compact else 22)
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.10, 0.10, 0.20, 0.55)
	bg.set_corner_radius_all(18)
	bg.set_content_margin_all(16.0 if _compact else 12.0)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14 if _compact else 10)
	panel.add_child(box)

	var slider := VSlider.new()
	slider.min_value = zoom_min
	slider.max_value = zoom_max
	# Coarse-ish step: every change rebuilds the node buttons, so don't fire per-pixel.
	slider.step = 0.05
	slider.value = _zoom_level
	slider.focus_mode = Control.FOCUS_NONE
	slider.tooltip_text = "Zoom"
	slider.custom_minimum_size = Vector2(96.0, 380.0) if _compact else Vector2(64.0, 300.0)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# Chunky track + gold fill + big round grabber (the theme defaults are tiny desktop-ware).
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.10, 0.10, 0.18, 0.75)
	track.set_corner_radius_all(10)
	var half_thick: float = 12.0 if _compact else 8.0
	track.content_margin_left = half_thick
	track.content_margin_right = half_thick
	slider.add_theme_stylebox_override("slider", track)
	var fill: StyleBoxFlat = track.duplicate()
	fill.bg_color = Color("f6b91e")
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	var grab := _make_grabber_tex(56 if _compact else 40)
	slider.add_theme_icon_override("grabber", grab)
	slider.add_theme_icon_override("grabber_highlight", grab)
	slider.add_theme_icon_override("grabber_disabled", grab)
	slider.value_changed.connect(func(v: float) -> void:
		_zoom_level = v
		_apply_zoom())

	box.add_child(_zoom_step_btn("+", 1.0, slider))
	box.add_child(slider)
	box.add_child(_zoom_step_btn("−", -1.0, slider))


func _zoom_step_btn(txt: String, dir: float, slider: Slider) -> Button:
	var b := Button.new()
	b.text = txt
	b.focus_mode = Control.FOCUS_NONE
	var s: float = 96.0 if _compact else 64.0
	b.custom_minimum_size = Vector2(s, s)
	b.add_theme_font_size_override("font_size", 48 if _compact else 32)
	b.pressed.connect(func() -> void: slider.value += dir * (zoom_max - zoom_min) / 6.0)
	return b


# A round gold grabber knob with a dark rim, built as a radial gradient (no art asset needed).
func _make_grabber_tex(diam: int) -> Texture2D:
	var tex := GradientTexture2D.new()
	tex.width = diam
	tex.height = diam
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var grad := Gradient.new()
	var gold := Color("f6b91e")
	var rim := Color(0.16, 0.12, 0.03)
	grad.offsets = PackedFloat32Array([0.0, 0.68, 0.76, 0.9, 1.0])
	grad.colors = PackedColorArray([gold, gold, rim, rim, Color(rim.r, rim.g, rim.b, 0.0)])
	tex.gradient = grad
	return tex


func _apply_zoom() -> void:
	_node_diam = _base_diam() * _zoom_level
	_build_map()


func _build_map() -> void:
	# Canvas width fits the scroll viewport at zoom 1 and grows with zoom (panning via scroll);
	# its height is whatever the floor spacing needs (always taller than the viewport, so it
	# scrolls vertically).
	var view: Vector2 = _scroll.size
	if view.x <= 0.0:
		# self is already sized by Shell's own layout to exclude the header and footer rows —
		# nothing here needs to account for their heights.
		view = size

	var floor_spacing: float = _node_diam * (floor_spacing_mult_compact if _compact else floor_spacing_mult)
	var canvas_w: float = view.x * maxf(1.0, _zoom_level)
	# The bottom pad includes a node diameter so the caption + reward text hanging below the
	# last row always clears the screen edge, at any zoom.
	var pad_bottom: float = V_PAD_BOTTOM + _node_diam
	var canvas_h: float = maxf(view.y, V_PAD_TOP + pad_bottom + floor_spacing * float(MapData.FLOORS - 1))
	_canvas.custom_minimum_size = Vector2(canvas_w, canvas_h)

	_calculate_positions(Vector2(canvas_w, canvas_h), floor_spacing, pad_bottom)
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
	var canvas_w: float = _canvas.custom_minimum_size.x
	var target_y: float
	var target_x: float = (canvas_w - _scroll.size.x) / 2.0
	if current_node_id >= 0 and node_positions.has(current_node_id):
		target_y = node_positions[current_node_id].y - _scroll.size.y / 2.0
		target_x = node_positions[current_node_id].x - _scroll.size.x / 2.0
	else:
		target_y = _canvas.custom_minimum_size.y   # start floor sits at the bottom of the canvas
	_scroll.scroll_vertical = int(maxf(0.0, target_y))
	_scroll.scroll_horizontal = int(maxf(0.0, target_x))


# Node x-positions follow the BRANCHING, not the abstract lane index: starting from the lane
# grid, each node is relaxed toward the average x of the nodes it connects to, so connected
# nodes sit close and trails stay short instead of stretching across the map. Each floor's
# nodes are kept in lane order with a minimum gap (so paths never cross or overlap). y comes
# straight from the floor. The result is then fit-to-width and centred.
func _calculate_positions(canvas_size: Vector2, floor_spacing: float, pad_bottom: float) -> void:
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

	_finalize_positions(canvas_size, floor_spacing, x_of, lane_spacing, pad_bottom)


# Fit the relaxed x-coordinates into the viewport width (shrink only if too wide), centre
# them, add optional organic jitter, and pair with the floor y.
func _finalize_positions(canvas_size: Vector2, floor_spacing: float, x_of: Dictionary,
		lane_spacing: float, pad_bottom: float) -> void:
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
	var usable_h: float = canvas_size.y - V_PAD_TOP - pad_bottom
	var half: float = _node_diam * 0.5
	var jitter := RandomNumberGenerator.new()

	for floor_nodes: Array in map_data.floors:
		for node: MapNodeData in floor_nodes:
			var x: float = canvas_center + (x_of[node.id] - graph_center) * scale
			var y: float = V_PAD_TOP + usable_h - float(node.floor) * floor_spacing
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
			med.configure(node.type, state, _node_diam, caption, reward_summary, reward_color)
			med.position = pos - Vector2(_node_diam, _node_diam) / 2.0
			if not reward_summary.is_empty():
				var label := caption if not caption.is_empty() else MapNodeData.get_label(node.type)
				med.tooltip_text = "%s — reward: %s" % [label, reward_summary]
			if is_reachable:
				var captured: MapNodeData = node
				med.pressed.connect(func():
					Vfx.play("map_node_select_ring", med)   # the pin-in-the-map ring
					_on_node_selected(captured))
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
	Nav.goto("res://scenes/game_world.tscn")
