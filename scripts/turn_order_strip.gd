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
const GAP := 2.0
const MIN_ENTRY := 16.0         # below this an entry stops being a picture of anything
const RADIUS := 5

# The turn number does not sit ON the thumbnail — the entry is a TITLED PANEL: a full-width header
# bar carrying the number, and the picture below it, sharing one outline. Nothing overlaps anything,
# so the art is never partly hidden by the number that names it, and the number gets a size it could
# never have inside a 50px thumbnail (it reads at relic-chip scale).
# A DIGIT's own height, as a share of the font size — measured off the UI font (Baloo2) from a
# render, because no font API reports cap height: at size 72 its numerals stand 45px, and at 18 they
# stand 11. Everything below depends on it, and it is the one number here that would need re-taking
# if the project's UI font changed. Note how far it is from the LINE BOX the font reports (Baloo2's
# height is 1.61x its font size): centring or sizing anything off ascent+descent puts a digit
# nowhere near the middle, which is exactly the bug this replaced.
const CAP_HEIGHT := 0.64
# The header's height, per unit of font size — the size of the INK, nothing more: the digit itself
# plus the stroke standing proud of it above and below. The empty descender and the ascender's
# overshoot are not the bar's problem; counting them is what doubled the bar's height.
const ENTRY_BOX := CAP_HEIGHT + NUM_OUTLINE * 2.0
const TAB_H := 0.42             # header height, as a fraction of the column width
const NUM_MIN_FONT := 18        # never smaller than the relic chips' numerals
const MAX_ASPECT := 1.5         # an entry may stand taller than the column is wide (cards are portrait)
# The entries OUT-DENT past the padding they sit in, half of this each side. The gutter's width is
# fixed (widening it would cost the boards their room), so the only place more picture can come from
# is the margin around the list — the entries take it and stand flush with the column's own frame.
const BLEED := 0.07

const BG := Color(0.10, 0.12, 0.20, 0.85)
# Side colour, all the way through: an entry is BLUE if it's ours and RED if it's theirs — header,
# outline and the number's own plate on the card, so "whose turn is this" is answered by the colour
# of the thing before any number is read. The LIGHT shade fills, the DARK shade draws the line
# around it: a lit panel on a dark gutter, rather than a dark hole punched in one.
const PLAYER_FILL := Color(0.46, 0.60, 0.92)
const ENEMY_FILL := Color(0.86, 0.44, 0.50)
const PLAYER_LINE := Color(0.07, 0.11, 0.24)
const ENEMY_LINE := Color(0.22, 0.06, 0.10)
const NUM_COLOR := Color(1.0, 1.0, 1.0)
# The numeral's outline is the panel's own line colour and HEAVY — the number sits on a light fill
# now, so without a thick stroke a white digit would dissolve into it. The panel's own border is
# cut from the same cloth: one weight for the whole widget, scaled off the column.
const NUM_OUTLINE := 0.34        # stroke size, as a fraction of the font size
const LINE_W := 0.075            # panel border, as a fraction of the column width

# The unit whose moment it is RIGHT NOW (see CombatWorld.acting): warm gold, the one colour on the
# strip that belongs to neither army, so "this is happening" can't be misread as "this is yours".
const ACTING_FILL := Color(1.0, 0.83, 0.34)
const ACTING_LINE := Color(0.36, 0.20, 0.02)

# Entry states, in the order they override each other (acting beats spent — a tapped unit's
# activate moment is still its moment).
const ST_READY := 0
const ST_SPENT := 1
const ST_ACTING := 2


# The side palettes, for anything that has to speak the same language as the strip (the turn number
# CardUI wears while the list is read — see CardUI._refresh_turn_number).
static func fill_color(owner_id: int) -> Color:
	return PLAYER_FILL if owner_id == 0 else ENEMY_FILL


static func line_color(owner_id: int) -> Color:
	return PLAYER_LINE if owner_id == 0 else ENEMY_LINE

# Injected by Combat before the strip enters the tree: where the order comes from, and who to
# tell when the cursor picks an entry out of it.
var world: CombatWorld = null
var board: CombatBoard = null

var _rows: VBoxContainer = null
var _order: Array = []          # the CardInstances currently listed, in turn order
var _sig: String = ""
var _hovered: CardInstance = null
var _line_w: int = 3            # the widget's border weight, scaled off the column in _lay_out
var _reading: bool = false      # the cursor is over the list AT ALL (see _process)
var _forced: bool = false       # a harness is standing in for the cursor (see point_at)


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
	# The order the board is showing is THIS order — a rebuild under a reading cursor (a death
	# mid-hover) must not leave the cards wearing the numbers of a list that no longer exists.
	_declare_numbers()


# One entry: a titled panel in the column's colours — a full-width header carrying the turn number,
# the card's art below it, one outline around both. Everything is POSITIONED in _lay_out (the
# entry's real width isn't known until the column is measured); this only builds the parts.
func _make_entry(inst: CardInstance, number: int) -> Control:
	var entry := Control.new()
	entry.mouse_filter = Control.MOUSE_FILTER_STOP
	entry.set_meta("inst", inst)

	# The picture's own box: the clip lives HERE, not on the entry, because the header sits outside
	# the picture and must not be cut off by the clip that keeps the art in its frame.
	var body := Control.new()
	body.clip_contents = true
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.add_child(body)

	var art := TextureRect.new()
	art.texture = inst.data.image
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# COVERED, not fitted: a thumbnail this small has to be a face, not a whole card shrunk to
	# illegibility. The clip above keeps the overflow off the neighbours.
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(art)

	# The picture's frame closes the panel on three sides — its top edge is the header's bottom
	# edge, so the two parts share ONE line instead of drawing a double rule between them.
	var frame := Panel.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(frame)

	# The header: full width, rounded where it caps the panel, square where it meets the picture.
	var plate := Panel.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.add_child(plate)

	var num := Label.new()
	num.text = str(number)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# TOP, not CENTER — the vertical placement is baseline_offset's job, and Godot's own centring
	# would be applied on top of it.
	num.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	num.add_theme_color_override("font_color", NUM_COLOR)
	entry.add_child(num)

	entry.set_meta("body", body)
	entry.set_meta("frame", frame)
	entry.set_meta("plate", plate)
	entry.set_meta("num", num)
	_dress(entry, inst, ST_READY)
	entry.mouse_entered.connect(func() -> void: _set_hovered(inst))
	entry.mouse_exited.connect(func() -> void:
		if _hovered == inst:
			_set_hovered(null))
	UIScale.tip(entry, Loc.t("combat.turn_order_entry",
			{"n": number, "name": inst.data.display_name}))
	return entry


# ── Entry state ─────────────────────────────────────────────────────────────────
# Three states, all DERIVED from live facts on the poll/frame beat (see _sync_states) rather than
# pushed by whoever changed them: READY (the unit will swing), SPENT (it is tapped — its turn comes
# up but no attack does; it wears the SAME grey the board greys it with, so the list and the board
# say "spent" the same way), and ACTING (its moment is being resolved right now).
func _dress(entry: Control, inst: CardInstance, state: int) -> void:
	var fill := ACTING_FILL if state == ST_ACTING else fill_color(inst.owner)
	var line := ACTING_LINE if state == ST_ACTING else line_color(inst.owner)

	var fs := StyleBoxFlat.new()
	fs.bg_color = Color(0, 0, 0, 0)
	fs.corner_radius_bottom_left = RADIUS
	fs.corner_radius_bottom_right = RADIUS
	fs.border_width_left = _line_w
	fs.border_width_right = _line_w
	fs.border_width_bottom = _line_w
	fs.border_color = line
	(entry.get_meta("frame") as Panel).add_theme_stylebox_override("panel", fs)

	var ps := StyleBoxFlat.new()
	ps.bg_color = fill
	ps.corner_radius_top_left = RADIUS
	ps.corner_radius_top_right = RADIUS
	ps.set_border_width_all(_line_w)
	ps.border_color = line
	(entry.get_meta("plate") as Panel).add_theme_stylebox_override("panel", ps)

	var num := entry.get_meta("num") as Label
	num.add_theme_color_override("font_outline_color", line)
	# The board's own exhaust grey, not a second opinion about what spent looks like.
	entry.modulate = CardUI.EXHAUST_TINT if state == ST_SPENT else Color.WHITE


# Re-derives every entry's state. Cheap by construction: the compare is an int and the dressing
# only runs on a change, so a strip nobody is looking at costs one loop of integer compares.
func _sync_states() -> void:
	if _rows == null:
		return
	var acting: CardInstance = world.acting if world != null else null
	for child in _rows.get_children():
		var entry := child as Control
		var inst: CardInstance = entry.get_meta("inst")
		var state := ST_READY
		if inst == acting:
			state = ST_ACTING
		elif inst.attack_exhausted:
			state = ST_SPENT
		if int(entry.get_meta("state", -1)) == state:
			continue
		entry.set_meta("state", state)
		_dress(entry, inst, state)


# Sizes the entries to the room the gutter actually has. A thumbnail may stand up to MAX_ASPECT
# taller than the column is wide (the art it crops is portrait, so height is worth more to it than
# width) and never shrinks below MIN_ENTRY — a board packed to both back rows simply runs the list
# off the bottom rather than grinding every entry down to an unreadable sliver. The tab costs only
# its exposed sliver: the rest of it overlaps the picture.
func _lay_out() -> void:
	if _rows == null or _order.is_empty() or size.x <= 0.0:
		return
	# The out-dent: the rows box is pushed wider than the strip on both sides, so every entry is
	# BLEED wider than the room the padding left it (see the constant).
	var bleed := size.x * BLEED * 0.5
	_rows.offset_left = -bleed
	_rows.offset_right = bleed
	var w := size.x + bleed * 2.0
	var count := _order.size()
	var room := (size.y - GAP * float(count - 1)) / float(count)
	_line_w = maxi(3, int(w * LINE_W))

	# The bar's height is the column's business — a fraction of the width, capped by the room a
	# crowded list leaves (24 entries, both boards packed to their back rows). The NUMBER then fits
	# itself to that bar through ENTRY_BOX, which counts the stroke: sizing the font off the bar
	# without counting it is what made the numerals bleed out, and sizing the BAR off the font is
	# what then made the bar huge. The bar leads; the font follows.
	var tab_h := clampf(minf(w * TAB_H, room * 0.5), 14.0, 30.0)
	var font := maxi(9, int(tab_h / ENTRY_BOX))
	var outline := maxi(2, int(font * NUM_OUTLINE))
	var body_h := clampf(room - tab_h, MIN_ENTRY, w * MAX_ASPECT)
	for child in _rows.get_children():
		var entry := child as Control
		entry.custom_minimum_size = Vector2(0.0, body_h + tab_h)
		var p: Panel = entry.get_meta("plate")
		p.position = Vector2.ZERO
		p.size = Vector2(w, tab_h)
		var num: Label = entry.get_meta("num")
		num.add_theme_font_size_override("font_size", font)
		num.add_theme_constant_override("outline_size", outline)
		# The label spans the header's width and its baseline is placed by hand (see baseline_offset).
		num.position = Vector2(0.0, baseline_offset(num, tab_h))
		num.size = Vector2(w, tab_h)
		var body: Control = entry.get_meta("body")
		# Butted against the header's bottom EDGE (inside its border), so the two share one line.
		body.position = Vector2(0.0, tab_h - float(_line_w))
		body.size = Vector2(w, body_h + float(_line_w))
	# The border weight is part of the dressing, and it just changed with the column.
	for child in _rows.get_children():
		var entry := child as Control
		_dress(entry, entry.get_meta("inst"), int(entry.get_meta("state", ST_READY)))


# Puts a numeral's DIGITS — not its line box — dead centre in a box `h` tall, by placing the
# BASELINE rather than nudging a centred label. Correcting Godot's own vertical centring means
# modelling it, and every model of it I tried was wrong by a few pixels in one direction or the
# other; placing the baseline needs no model. The label is TOP-aligned, which puts its baseline one
# ascent below its rect, so the rect's offset is simply "where the baseline should be, minus one
# ascent". A digit stands from the baseline up to its cap height and nothing hangs below it, so
# centred ink means the baseline sits half a cap below the middle.
#
# THE CALLER MUST TOP-ALIGN THE LABEL (see _make_entry) — under centre alignment this offset is
# applied on top of Godot's centring and the numeral lands low, which is exactly the bug it fixes.
static func baseline_offset(num: Label, h: float) -> float:
	var font: Font = num.get_theme_font("font")
	if font == null:
		return 0.0
	var px := num.get_theme_font_size("font_size")
	return h * 0.5 + CAP_HEIGHT * float(px) * 0.5 - font.get_ascent(px)


# ── Reading the list ────────────────────────────────────────────────────────────
# Pointing at ONE entry lights that unit; pointing at the LIST AT ALL writes the whole order onto
# the board — every unit wears its own number where it stands, so the question "who goes when"
# is answered on the battlefield instead of by walking the eye back and forth between two places.
#
# Hit-tested per frame rather than taken from mouse_entered/mouse_exited: the entries sit on top
# of this control and steal those signals from it, so a parent-level enter/exit would blink off
# the moment the cursor found an entry. One rect test a frame cannot be wrong that way.
func _process(_delta: float) -> void:
	# Per frame, not on the 0.2s poll: the acting cue has to keep up with the swing it names.
	_sync_states()
	if _forced:
		return
	var area := get_parent() as Control   # the gutter's padding box — the whole visible column
	var rect := area.get_global_rect() if area != null else get_global_rect()
	_set_reading(rect.has_point(get_global_mouse_position()))


func _set_reading(on: bool) -> void:
	if on == _reading:
		return
	_reading = on
	_declare_numbers()


# Hands the board the order it should be showing (empty = show nothing). Declared, never pushed:
# the cards derive their own numbers from it, exactly as they do the spotlight.
func _declare_numbers() -> void:
	if board != null:
		board.declare_turn_numbers(_order if _reading else [])


# The units currently listed, in turn order — a read for whoever wants to talk about the strip's
# contents (the render harness's turnhover shot) without re-deriving the order.
func listed() -> Array:
	return _order.duplicate()


# Points at a unit as though the cursor had entered its entry (null = point at nothing). The
# harness's door into the hover, and the one place a caller other than the entries themselves
# may move the spotlight. Also stands in for the cursor being over the list, and LATCHES that:
# the harness has no real mouse, so the per-frame hit test would immediately answer "not reading"
# and undo it.
func point_at(inst: CardInstance) -> void:
	_forced = inst != null
	_set_hovered(inst)
	_set_reading(_forced)


# The cursor picked a unit out of the list: DECLARE it (the board owns the declaration, cards
# derive their own look from it — see CombatBoard.declare_spotlight). Nothing is pushed at the
# card itself, so the lit unit cannot outlive the hover that lit it.
func _set_hovered(inst: CardInstance) -> void:
	if inst == _hovered:
		return
	_hovered = inst
	if board != null:
		board.declare_spotlight(inst)
