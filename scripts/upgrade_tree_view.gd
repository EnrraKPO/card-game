class_name UpgradeTreeView
extends Control

# Renders one UpgradeTree as a grid of node cards, drawing link lines from each node back to
# its prerequisites (links are drawn in _draw, so they sit behind the cards). Clicking a card
# emits `node_selected` so the screen can preview/buy the node; refresh_states() recolours the
# cards by ownership (owned / available / locked) against the active profile.
#
# The grid SCALES TO FILL the available area and CENTERS itself: a small tree blows up to occupy
# the canvas (capped at MAX_SCALE) instead of sitting tiny in a corner; a tree larger than the
# viewport stays at scale 1 and scrolls. Layout re-runs whenever the view is resized.

signal node_selected(node: UpgradeNode)

const CELL := Vector2(210, 188)          # base grid pitch between node centres (desktop)
const CELL_COMPACT := Vector2(250, 215)
const CARD_INSET := Vector2(40, 44)      # card size = cell - inset
const PAD := Vector2(48, 36)             # margin around the grid
const MAX_SCALE := 1.6                   # how far a small tree may blow up to fill the canvas
const MIN_SCALE := 0.45                  # how far a large tree may shrink so it still fits

const OWNED_TINT := Color(0.55, 0.95, 0.6)    # bought
const LOCKED_TINT := Color(0.5, 0.5, 0.55)    # prerequisites not yet owned

var _tree: UpgradeTree
var _compact := false
var _link_color := Color(0.4, 0.42, 0.5, 0.65)
var _positions: Dictionary = {}          # node id -> Vector2 (card top-left, absolute)
var _cards: Dictionary = {}              # node id -> { "button": Button, "name": Label, "node": UpgradeNode }
var _card_size: Vector2
var _link_width := 2.0


func setup(compact: bool) -> UpgradeTreeView:
	_compact = compact
	resized.connect(_relayout)
	return self


func show_tree(tree: UpgradeTree) -> void:
	_tree = tree
	_relayout()


# (Re)builds the card grid, scaled to fill the current view size and centred. Runs on show_tree
# and on every resize so the tree always occupies the canvas.
func _relayout() -> void:
	for c in get_children():
		c.queue_free()
	_positions.clear()
	_cards.clear()
	if _tree == null:
		custom_minimum_size = Vector2.ZERO
		queue_redraw()
		return

	_link_color = _tree.color.darkened(0.15)
	_link_color.a = 0.7

	var max_row := 0
	var max_col := 0
	for n: UpgradeNode in _tree.nodes:
		max_row = maxi(max_row, n.row)
		max_col = maxi(max_col, n.col)

	var base_cell := CELL_COMPACT if _compact else CELL
	var base_card := base_cell - CARD_INSET
	# Natural footprint at scale 1 (last node's far edge included).
	var natural := Vector2(max_col * base_cell.x, max_row * base_cell.y) + base_card
	var avail := (size - PAD * 2.0).max(Vector2.ONE)

	# Scale to fill the available area and always fit it: blow a small tree up (capped at MAX_SCALE),
	# shrink a large one down (floored at MIN_SCALE) so the whole tree stays visible and centred —
	# we never scroll. (custom_minimum_size stays ZERO so this view just fills the scroll viewport.)
	custom_minimum_size = Vector2.ZERO
	var scale := 1.0
	if natural.x > 0.0 and natural.y > 0.0:
		scale = clampf(minf(avail.x / natural.x, avail.y / natural.y), MIN_SCALE, MAX_SCALE)

	var cell := base_cell * scale
	_card_size = base_card * scale
	_link_width = (3.0 if _compact else 2.0) * scale
	var content := Vector2(max_col * cell.x, max_row * cell.y) + _card_size
	var origin := ((size - content) * 0.5).max(PAD)

	for n: UpgradeNode in _tree.nodes:
		var pos := origin + Vector2(n.col * cell.x, n.row * cell.y)
		_positions[n.id] = pos
		_add_card(n, pos, scale)

	refresh_states()
	queue_redraw()


# Recolours each card by ownership against the active profile: owned (green ✓), available
# (full tree colour), or locked (dimmed). Called after building a tree and after a purchase.
func refresh_states() -> void:
	var profile := GameData.current_profile
	for nid: String in _cards:
		var entry: Dictionary = _cards[nid]
		var node: UpgradeNode = entry["node"]
		var btn: Button = entry["button"]
		var name_lbl: Label = entry["name"]
		name_lbl.text = node.display_name
		if profile == null:
			btn.modulate = Color.WHITE
		elif profile.owns_upgrade(node.id):
			btn.modulate = OWNED_TINT
			name_lbl.text = "%s ✓" % node.display_name
		elif profile.upgrade_unlocked(node):
			btn.modulate = Color.WHITE
		else:
			btn.modulate = LOCKED_TINT


func _add_card(n: UpgradeNode, pos: Vector2, scale: float) -> void:
	var btn := Button.new()
	btn.position = pos
	btn.custom_minimum_size = _card_size
	btn.size = _card_size
	btn.clip_text = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "%s\nCost: %d\n\n%s" % [n.display_name, n.cost, n.description]
	btn.pressed.connect(func() -> void: node_selected.emit(n))
	add_child(btn)

	# Content (icon over name); ignore mouse so clicks fall through to the button.
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", int(4 * scale))
	btn.add_child(box)

	var icon := Label.new()
	icon.text = n.icon
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", int((30 if _compact else 26) * scale))
	box.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = n.display_name
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.custom_minimum_size.x = _card_size.x
	name_lbl.add_theme_font_size_override("font_size", int((18 if _compact else 15) * scale))
	box.add_child(name_lbl)

	_cards[n.id] = { "button": btn, "name": name_lbl, "node": n }


func _draw() -> void:
	if _tree == null:
		return
	var half := _card_size * 0.5
	for n: UpgradeNode in _tree.nodes:
		if not _positions.has(n.id):
			continue
		var to: Vector2 = _positions[n.id] + half
		for req: String in n.requires:
			if _positions.has(req):
				var from: Vector2 = _positions[req] + half
				draw_line(from, to, _link_color, _link_width, true)
