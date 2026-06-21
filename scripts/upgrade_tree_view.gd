class_name UpgradeTreeView
extends Control

# Renders one UpgradeTree as a grid of node cards, drawing link lines from each node back to
# its prerequisites (links are drawn in _draw, so they sit behind the cards). Clicking a card
# emits `node_selected` so the screen can preview/buy the node; refresh_states() recolours the
# cards by ownership (owned / available / locked) against the active profile.

signal node_selected(node: UpgradeNode)

const CELL := Vector2(168, 150)          # grid pitch between node centres (desktop)
const CELL_COMPACT := Vector2(228, 196)
const PAD := Vector2(48, 36)             # margin around the grid

const OWNED_TINT := Color(0.55, 0.95, 0.6)    # bought
const LOCKED_TINT := Color(0.5, 0.5, 0.55)    # prerequisites not yet owned

var _tree: UpgradeTree
var _compact := false
var _link_color := Color(0.4, 0.42, 0.5, 0.65)
var _positions: Dictionary = {}          # node id -> Vector2 (card top-left)
var _cards: Dictionary = {}              # node id -> { "button": Button, "name": Label, "node": UpgradeNode }
var _card_size: Vector2


func setup(compact: bool) -> UpgradeTreeView:
	_compact = compact
	_card_size = (CELL_COMPACT if compact else CELL) - Vector2(40, 44)
	return self


func show_tree(tree: UpgradeTree) -> void:
	_tree = tree
	for c in get_children():
		c.queue_free()
	_positions.clear()
	_cards.clear()
	if tree == null:
		custom_minimum_size = Vector2.ZERO
		queue_redraw()
		return

	_link_color = tree.color.darkened(0.15)
	_link_color.a = 0.7
	var cell := CELL_COMPACT if _compact else CELL
	var max_row := 0
	var max_col := 0
	for n: UpgradeNode in tree.nodes:
		max_row = maxi(max_row, n.row)
		max_col = maxi(max_col, n.col)
		var pos := PAD + Vector2(n.col * cell.x, n.row * cell.y)
		_positions[n.id] = pos
		_add_card(n, pos)

	custom_minimum_size = PAD * 2 + Vector2(max_col * cell.x, max_row * cell.y) + _card_size
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


func _add_card(n: UpgradeNode, pos: Vector2) -> void:
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
	box.add_theme_constant_override("separation", 2)
	btn.add_child(box)

	var icon := Label.new()
	icon.text = n.icon
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", 30 if _compact else 24)
	box.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = n.display_name
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.custom_minimum_size.x = _card_size.x
	name_lbl.add_theme_font_size_override("font_size", 17 if _compact else 13)
	box.add_child(name_lbl)

	_cards[n.id] = { "button": btn, "name": name_lbl, "node": n }


func _draw() -> void:
	if _tree == null:
		return
	var half := _card_size * 0.5
	var width := 3.0 if _compact else 2.0
	for n: UpgradeNode in _tree.nodes:
		if not _positions.has(n.id):
			continue
		var to: Vector2 = _positions[n.id] + half
		for req: String in n.requires:
			if _positions.has(req):
				var from: Vector2 = _positions[req] + half
				draw_line(from, to, _link_color, width, true)
