class_name TurnOrderStrip
extends Control

# WHO ACTS NEXT — the fight's activation order, standing in the gutter between the two armies
# because it belongs to neither and describes both. One entry per unit on the board, top to
# bottom in the order the round will walk: a thumbnail of the card's art and the turn number it
# holds. Pointing at an entry lights that unit where it stands, so the list and the board can be
# read as one thing instead of two.
#
# The order is NOT this strip's to compute — it asks CombatWorld.turn_order, the same call the
# round loop walks. A display that derived its own order could promise something the fight then
# breaks, which is the whole reason that sort lives in one place.
#
# SELF-POLLING, like the rest of combat's presentation (see CardUI.derive_presentation): nothing
# in the game pushes "the order changed" at anything — placements, moves, deaths, buffs and
# speed debuffs all change it, and a strip that had to be told about each of them would be wrong
# the first time a path forgot. Instead the strip re-asks on a slow beat and rebuilds only when
# the answer actually differs (see _signature).

const POLL_SECS := 0.2
const GAP := 3.0
const MIN_ENTRY := 20.0         # below this an entry stops being a picture of anything
const NUM_PLATE := 0.44         # the turn-number plate, as a fraction of the column width
const RADIUS := 5

const BG := Color(0.10, 0.12, 0.20, 0.85)
const PLAYER_EDGE := Color(0.46, 0.60, 0.92)
const ENEMY_EDGE := Color(0.86, 0.44, 0.50)
const NUM_PLATE_BG := Color(0.06, 0.07, 0.12, 0.88)
const NUM_COLOR := Color(0.95, 0.97, 1.0)

# Injected by Combat before the strip enters the tree: where the order comes from, and who to
# tell when the cursor picks an entry out of it.
var world: CombatWorld = null
var board: CombatBoard = null

var _rows: VBoxContainer = null
var _order: Array = []          # the CardInstances currently listed, in turn order
var _sig: String = ""
var _hovered: CardInstance = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows = VBoxContainer.new()
	# Top-aligned by construction: the list grows DOWN from the top of the gutter, so entry 1 is
	# always in the same place whether the board holds two units or sixteen.
	_rows.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows.add_theme_constant_override("separation", int(GAP))
	add_child(_rows)

	var poll := Timer.new()
	poll.wait_time = POLL_SECS
	poll.autostart = true
	poll.timeout.connect(refresh)
	add_child(poll)
	resized.connect(_lay_out)
	refresh()


# Re-asks the world for its order and rebuilds if it differs. Cheap enough to poll: the compare
# is one string, and a board holds at most a couple of dozen units.
func refresh() -> void:
	if world == null:
		return
	var order := world.turn_order()
	var sig := _signature(order)
	if sig == _sig:
		return
	_sig = sig
	_order = order
	_rebuild()


# What a rebuild depends on: which units are listed and in what order. Their STATS are not part
# of it — a wounded unit's thumbnail is the same thumbnail — but a speed change reorders the
# list, and that shows up here as a different sequence.
func _signature(order: Array) -> String:
	var parts: PackedStringArray = []
	for inst: CardInstance in order:
		parts.append("%d" % inst.get_instance_id())
	return ",".join(parts)


func _rebuild() -> void:
	# A rebuild can pull the hovered entry out from under the cursor (its unit just died). Drop
	# the spotlight with it rather than leaving a dead unit lit on a board it has left.
	_set_hovered(null)
	# remove THEN free: queue_free leaves the node in the tree until the end of the frame, so
	# freeing alone would lay the new list out underneath the old one for a frame.
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	for i in _order.size():
		_rows.add_child(_make_entry(_order[i], i + 1))
	_lay_out()


# One entry: the card's art, filling the column, with its turn number on a plate in the corner.
# The frame is tinted by side, so "whose turn is this" is answerable without reading the art.
func _make_entry(inst: CardInstance, number: int) -> Control:
	var entry := Control.new()
	entry.mouse_filter = Control.MOUSE_FILTER_STOP
	entry.clip_contents = true
	entry.set_meta("inst", inst)

	var art := TextureRect.new()
	art.texture = inst.data.image
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# COVERED, not fitted: a thumbnail this small has to be a face, not a whole card shrunk to
	# illegibility. The clip above keeps the overflow off the neighbours.
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.add_child(art)

	var frame := Panel.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fs := StyleBoxFlat.new()
	fs.bg_color = Color(0, 0, 0, 0)
	fs.set_corner_radius_all(RADIUS)
	fs.set_border_width_all(2)
	fs.border_color = PLAYER_EDGE if inst.owner == 0 else ENEMY_EDGE
	frame.add_theme_stylebox_override("panel", fs)
	entry.add_child(frame)

	var plate := Panel.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ps := StyleBoxFlat.new()
	ps.bg_color = NUM_PLATE_BG
	ps.set_corner_radius_all(RADIUS)
	plate.add_theme_stylebox_override("panel", ps)
	entry.add_child(plate)

	var num := Label.new()
	num.text = str(number)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.add_theme_color_override("font_color", NUM_COLOR)
	entry.add_child(num)

	entry.set_meta("plate", plate)
	entry.set_meta("num", num)
	entry.mouse_entered.connect(func() -> void: _set_hovered(inst))
	entry.mouse_exited.connect(func() -> void:
		if _hovered == inst:
			_set_hovered(null))
	UIScale.tip(entry, Loc.t("combat.turn_order_entry",
			{"n": number, "name": inst.data.display_name}))
	return entry


# Sizes the entries to the room the gutter actually has. Entries never grow past the column's
# own width (a square is as much thumbnail as a narrow column can carry) and never shrink below
# MIN_ENTRY — a board packed to both back rows simply runs the list off the bottom rather than
# grinding every entry down to an unreadable sliver.
func _lay_out() -> void:
	if _rows == null or _order.is_empty() or size.x <= 0.0:
		return
	var count := _order.size()
	var room := (size.y - GAP * float(count - 1)) / float(count)
	var h := clampf(room, MIN_ENTRY, size.x)
	var plate := maxf(10.0, minf(h * 0.62, size.x * NUM_PLATE))
	for child in _rows.get_children():
		var entry := child as Control
		entry.custom_minimum_size = Vector2(0.0, h)
		var p: Panel = entry.get_meta("plate")
		p.position = Vector2.ZERO
		p.size = Vector2(plate, plate)
		var num: Label = entry.get_meta("num")
		num.position = Vector2.ZERO
		num.size = Vector2(plate, plate)
		num.add_theme_font_size_override("font_size", maxi(9, int(plate * 0.66)))


# The units currently listed, in turn order — a read for whoever wants to talk about the strip's
# contents (the render harness's turnhover shot) without re-deriving the order.
func listed() -> Array:
	return _order.duplicate()


# Points at a unit as though the cursor had entered its entry (null = point at nothing). The
# harness's door into the hover, and the one place a caller other than the entries themselves
# may move the spotlight.
func point_at(inst: CardInstance) -> void:
	_set_hovered(inst)


# The cursor picked a unit out of the list: DECLARE it (the board owns the declaration, cards
# derive their own look from it — see CombatBoard.declare_spotlight). Nothing is pushed at the
# card itself, so the lit unit cannot outlive the hover that lit it.
func _set_hovered(inst: CardInstance) -> void:
	if inst == _hovered:
		return
	_hovered = inst
	if board != null:
		board.declare_spotlight(inst)
