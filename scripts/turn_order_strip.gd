class_name TurnOrderStrip
extends Control

# WHO ACTS NEXT — the fight's activation order, standing in the gutter between the two armies
# because it belongs to neither and describes both. One entry per unit on the board, top to
# bottom in the order the round will walk: a thumbnail of the card's art and the turn number it
# holds. Pointing at an entry lights that unit where it stands, so the list and the board can be
# read as one thing instead of two.
#
# Salvaged whole from the pre-swap tree (H2/H3); the reads re-terminated on the new core:
# the order is NOT this strip's to compute — it asks CombatCascade.turn_order, the same call
# the clock walks at the span's open. A display that derived its own order could promise
# something the fight then breaks, which is the whole reason that sort lives in one place.
#
# SELF-POLLING, like the rest of combat's presentation (see CardUI.derive_presentation): nothing
# in the game pushes "the order changed" at anything — placements, moves, deaths, buffs and
# speed debuffs all change it, and a strip that had to be told about each of them would be wrong
# the first time a path forgot. Instead the strip re-asks on a slow beat and rebuilds only when
# the answer actually differs (see _signature).

# ── The striped ring, drawn ──────────────────────────────────────────────────────
# A dashed rounded-rect stroke around a widget, in two alternating colours. Drawn rather than
# textured: an asset would have to be re-cut for every stroke weight, dash length and corner radius
# the strip computes off its live column width, and would resample badly at the sizes a packed list
# produces. This is pure arithmetic — it repaints only when something actually changes, and every
# knob stays a number.
#
# THE SEAM RULE: the dash length is not used as given. The perimeter is measured first and the
# segment resized to divide it into an EVEN number of parts, so the walk comes back to its start on
# the opposite colour and the loop closes without two same-coloured dashes meeting. Without that,
# every entry height produces its own seam artefact somewhere on the ring.
class DashRing extends Control:
	# Per corner. A thick stroke turns each chord joint into a visible mitre spike, so the corners
	# need more subdivision than their ~5px radius suggests.
	const ARC_STEPS := 6

	var stroke: float = 4.0
	var dash: float = 9.0
	var radius: float = 5.0
	var _a: Color = Color.WHITE
	var _b: Color = Color.WHITE

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# The path is derived from `size`, and a Control is not redrawn just because it was resized.
		resized.connect(queue_redraw)

	func set_stripes(a: Color, b: Color) -> void:
		if a == _a and b == _b:
			return
		_a = a
		_b = b
		queue_redraw()

	# Called by the strip's layout: everything the ring's geometry depends on, in one go.
	func set_metrics(p_stroke: float, p_dash: float, p_radius: float) -> void:
		if is_equal_approx(stroke, p_stroke) and is_equal_approx(dash, p_dash) \
				and is_equal_approx(radius, p_radius):
			return
		stroke = p_stroke
		dash = p_dash
		radius = p_radius
		queue_redraw()

	func _draw() -> void:
		if size.x <= stroke or size.y <= stroke:
			return
		var pts := _path()
		var perim := 0.0
		for i in pts.size() - 1:
			perim += pts[i].distance_to(pts[i + 1])
		if perim <= 0.0:
			return
		# EVEN number of segments, at least two — see THE SEAM RULE above.
		var count := maxi(2, int(round(perim / maxf(dash, 1.0) * 0.5)) * 2)
		var seg := perim / float(count)
		var used := 0.0      # how much of the current segment is already laid down
		var odd := false     # which colour the current segment is
		for i in pts.size() - 1:
			var p0 := pts[i]
			var p1 := pts[i + 1]
			var d := p0.distance_to(p1)
			if d <= 0.0001:
				continue
			var t := 0.0
			while t < d - 0.0001:
				var step := minf(d - t, seg - used)
				draw_line(p0.lerp(p1, t / d), p0.lerp(p1, (t + step) / d),
						_b if odd else _a, stroke, true)
				used += step
				t += step
				if used >= seg - 0.0001:
					used = 0.0
					odd = not odd

	# The rounded-rect path as a closed polyline, INSET by half the stroke so the drawn band sits
	# inside the widget's box rather than half outside it (draw_line centres its width on the line).
	func _path() -> PackedVector2Array:
		var inset := stroke * 0.5
		var box := Rect2(Vector2(inset, inset), size - Vector2(inset, inset) * 2.0)
		var r := maxf(0.0, minf(radius, minf(box.size.x, box.size.y) * 0.5))
		var arcs := [
			[Vector2(box.position.x + r, box.position.y + r), PI, PI * 1.5],
			[Vector2(box.end.x - r, box.position.y + r), PI * 1.5, TAU],
			[Vector2(box.end.x - r, box.end.y - r), 0.0, PI * 0.5],
			[Vector2(box.position.x + r, box.end.y - r), PI * 0.5, PI],
		]
		var pts := PackedVector2Array()
		for arc: Array in arcs:
			var centre: Vector2 = arc[0]
			var from: float = arc[1]
			var to: float = arc[2]
			for i in ARC_STEPS + 1:
				var ang: float = from + (to - from) * float(i) / float(ARC_STEPS)
				pts.append(centre + Vector2(cos(ang), sin(ang)) * r)
		pts.append(pts[0])   # close the loop
		return pts


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

# The unit whose moment it is RIGHT NOW (see FightScreen.acting): warm gold, the one colour on the
# strip that belongs to neither army, so "this is happening" can't be misread as "this is yours".
const ACTING_FILL := Color(1.0, 0.83, 0.34)
const ACTING_LINE := Color(0.36, 0.20, 0.02)

# ── The PICK's ring: "this unit is the one you chose" ───────────────────────────
# A STRIPED border replacing the entry's own — alternating white and the entry's own fill colour,
# walked around its outline (see DashRing). Chosen against every kind of emphasis the strip already
# spends, because a pick is a state the player put the card in and LEFT it in: it has to survive
# being looked at for a long time without shouting, and it has to coexist with the hover.
#
# BROKEN vs UNBROKEN is the whole idea. The hover is a solid ring just OUTSIDE the entry's
# silhouette; this is a dashed ring ON it. The eye separates a broken ring from a continuous one
# without comparing colours or sizes, so the two read as two rings — nested, not competing — where
# a second solid outline in another colour would have read as one confused one.
#
# The stripes alternate with the entry's FILL, never with its line shade: that keeps "whose unit is
# this" inside the selection cue itself, and white against the near-black line shade would go muddy
# on the dark gutter.
# Both of these are smaller than they look like they should be. An entry is ~62px wide and, in the
# packed case, barely 35px tall — a stroke at 1.5x the border and dashes a sixth of the width came
# out as a ring of BLOCKS that swallowed the thumbnail, not as stripes. The dash has to stay short
# relative to the stroke for the eye to read "broken line" rather than "checkerboard".
# DATA, like the rest of the family: the `turn_entry_selected` entry in data/vfx/vfx.json carries
# line_mul / dash / saturation / stripe_color, tunable in the Tool. Nothing plays that entry — the
# strip reads it. The constants here are fallbacks for a missing entry, not the authority.
const SEL_LINE_MUL := 1.25   # stroke weight, as a multiple of the entry's own border
const SEL_DASH := 0.10       # segment length along the perimeter, as a fraction of the column width
const SEL_WHITE := Color(1.0, 1.0, 1.0)
# The coloured stripes are the header's own colour PUSHED — the fill is a pale tint (it has to sit
# under white text), and at that saturation the stripes read as two shades of nearly-white rather
# than as a colour alternating with white. Saturation only: the hue stays the entry's, so it is
# still visibly the same blue or red, just stated properly.
const SEL_SAT := 1.6

# Entry states, in the order they override each other (acting beats spent by precedence).
# DECLARED GAP vs the pre-nuke strip: the old cascade pointer lit EVERY unit's moment,
# tapped ones included (their actless moment still fired). The new acting fact rides the
# beat stream (Mutation §11; see FightScreen.acting), and a moment that produces no authored windup
# — a tapped unit's pass-over — emits no beat, so it cannot light. Getting that moment
# back needs the core to speak it: an engine ruling matter, not a UI edit.
const ST_READY := 0
const ST_SPENT := 1
const ST_ACTING := 2

# ── Standing proud of the gutter ────────────────────────────────────────────────
# Two entries in the list get to break its edge: the one the cursor is pointing at, and the one
# whose moment it is. The gutter is only ~58px wide, so there is no room INSIDE it for an emphasis
# that reads — the only direction left is OUT. Both lifts are pure canvas transforms (see
# _apply_lift), so nothing in the list moves and no neighbour is displaced; the entry simply grows
# over the boards on either side. Acting outranks hover: it is a fact about the fight, not about
# the cursor, and it must not shrink when the cursor happens to land on it.
#
# THE FACTORS ARE THE ENTRIES' OWN `scale` — read from `turn_entry_hover` / `turn_entry_acting` in
# data/vfx/vfx.json rather than kept here. Those entries already authored a scale (it is what
# HighlightFx would grow by if the strip used its grow), so a constant here was the same number
# maintained in two places, free to drift the moment either was tuned. The values below are
# fallbacks for a missing entry, not the authority. `lift_time` rides the same entries.
const LIFT_HOVER := 1.07
const LIFT_ACTING := 1.10
const LIFT_TIME := 0.14
const LIFT_META := "turn_lift"     # the factor currently applied — the change-guard
const LIFT_TWEEN := "turn_lift_tw"  # the entry's one in-flight scale tween


# The side palettes, for anything that has to speak the same language as the strip (the turn number
# CardUI wears while the list is read — see CardUI._refresh_turn_number).
static func fill_color(owner_id: int) -> Color:
	return PLAYER_FILL if owner_id == 0 else ENEMY_FILL


static func line_color(owner_id: int) -> Color:
	return PLAYER_LINE if owner_id == 0 else ENEMY_LINE


# The same colour, said louder — saturation pushed, hue and brightness left alone, so the result is
# recognisably the colour it came from rather than a second colour to keep in step with the first.
static func saturated(c: Color, mul: float) -> Color:
	var out := c
	out.s = clampf(c.s * mul, 0.0, 1.0)
	return out

# Injected by FightScreen before the strip enters the tree: where the order comes from, and who to
# tell when the cursor picks an entry out of it.
var world: World = null
var screen: FightScreen = null

var _rows: VBoxContainer = null
var _order: Array[Unit] = []    # the units currently listed, in turn order
var _sig: String = ""
var _hovered: Unit = null
# Attention arriving from the BOARD side — TWO facts, not one, because they mean different things
# and get different looks (see _sync_attention). The cursor resting on a card is the same transient
# gesture as the cursor resting on an entry; the pick is a lasting state.
var _marked: Unit = null     # the cursor is on this unit's CARD
var _selected: Unit = null   # this unit is the pick — the inverted skin (see _dress)
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


# Which half a unit fights for, as the palette index the colours above are keyed by:
# 0 = the player's, 1 = the enemy's. Allegiance is the birth fact (Core §1); the palette
# derives it here at the seam.
func _owner_of(unit: Unit) -> int:
	return 0 if world != null and unit.allegiance == world.player_side() else 1


# A unit is SPENT when its tapped stat stands raised — the same fact the untapped baked
# condition reads (Combat Frame §6).
func _spent(unit: Unit) -> bool:
	return unit.get_stat(&"tapped") > 0.0


# The thumbnail's art: the unit's authored catalogue face (CardViewModel resolves the
# seat and falls back to the placeholder for an id with none).
func _art_of(unit: Unit) -> Texture2D:
	return CardViewModel.card_face(unit).image


# Re-asks the world for its order and rebuilds if it differs. Cheap enough to poll: the compare
# is one string, and a board holds at most a couple of dozen units.
func refresh() -> void:
	if world == null:
		return
	var order: Array[Unit] = CombatCascade.turn_order(world)
	var sig := _signature(order)
	if sig == _sig:
		return
	_sig = sig
	_order = order
	_rebuild()


# What a rebuild depends on: which units are listed and in what order. Their STATS are not part
# of it — a wounded unit's thumbnail is the same thumbnail — but a speed change reorders the
# list, and that shows up here as a different sequence.
func _signature(order: Array[Unit]) -> String:
	var parts: PackedStringArray = []
	for unit: Unit in order:
		parts.append("%d" % unit.get_instance_id())
	return ",".join(parts)


func _rebuild() -> void:
	# A rebuild can pull the hovered entry out from under the cursor (its unit just died). Drop
	# the spotlight with it rather than leaving a dead unit lit on a board it has left.
	_set_hovered(null)
	# The board-side facts are FORGOTTEN, not carried: every entry below is a new widget, and a mark
	# whose value never changed would never be re-applied to the one that replaced it. Dropping them
	# makes the next _sync_attention see a change and re-apply — one frame later, at the cost of
	# nothing, and correct for the unit that died as well as the one that didn't.
	_marked = null
	_selected = null
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
func _make_entry(unit: Unit, number: int) -> Control:
	var entry := Control.new()
	entry.mouse_filter = Control.MOUSE_FILTER_STOP
	entry.set_meta("inst", unit)

	# The picture's own box: the clip lives HERE, not on the entry, because the header sits outside
	# the picture and must not be cut off by the clip that keeps the art in its frame.
	var body := Control.new()
	body.clip_contents = true
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.add_child(body)

	var art := TextureRect.new()
	art.texture = _art_of(unit)
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

	# LAST child, so the pick's ring lays over the header and the picture frame it replaces rather
	# than under them. Hidden until the pick says otherwise (see _dress).
	var ring := DashRing.new()
	ring.visible = false
	entry.add_child(ring)

	entry.set_meta("body", body)
	entry.set_meta("frame", frame)
	entry.set_meta("plate", plate)
	entry.set_meta("num", num)
	entry.set_meta("ring", ring)
	_dress(entry, unit, ST_READY)
	entry.mouse_entered.connect(func() -> void: _set_hovered(unit))
	entry.mouse_exited.connect(func() -> void:
		if _hovered == unit:
			_set_hovered(null))
	entry.gui_input.connect(func(event: InputEvent) -> void: _on_entry_input(event, unit))
	UIScale.tip(entry, Loc.t("combat.turn_order_entry",
			{"n": number, "name": unit.display_name}))
	return entry


# ── Entry state ─────────────────────────────────────────────────────────────────
# Three states, all DERIVED from live facts on the poll/frame beat (see _sync_states) rather than
# pushed by whoever changed them: READY (the unit will swing), SPENT (it is tapped — its turn comes
# up but no attack does; it wears the SAME grey the board greys it with, so the list and the board
# say "spent" the same way), and ACTING (its moment is being resolved right now).
#
# The PICK is a fourth thing, on an axis of its own: it changes no colour the state chose, it lays
# a striped ring over the entry's own border (see the PICK'S RING block above and DashRing). So a
# selected unit that is also acting still reads gold, and every state below still reads exactly as
# it did. Derived here from Selection like everything else — `_dress` is the one place the entry's
# skin is decided, and asking is what keeps it that way.
func _dress(entry: Control, unit: Unit, state: int) -> void:
	var fill := ACTING_FILL if state == ST_ACTING else fill_color(_owner_of(unit))
	var line := ACTING_LINE if state == ST_ACTING else line_color(_owner_of(unit))

	# The pick's ring, alternating white with the fill the state just chose — so it says "chosen"
	# and "whose, and doing what" in the same stroke. Sized in _lay_out with everything else.
	var ring := entry.get_meta("ring") as DashRing
	ring.visible = unit == _selected
	if ring.visible:
		var vd := VFXData.get_vfx("turn_entry_selected")
		var stripe := vd.color_param("stripe_color", SEL_WHITE) if vd != null else SEL_WHITE
		ring.set_stripes(stripe, saturated(fill,
				Vfx.param_of("turn_entry_selected", "saturation", SEL_SAT)))

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
	_refresh_cues(entry)


# ── The two emphases an entry can wear ──────────────────────────────────────────
# DERIVED, never pushed: an entry's cues are a pure function of its state meta and who the cursor
# is pointing at, so every path that changes either one (a rebuild, a state flip, a hover) just
# calls this and cannot leave a stale glow behind. Both cues are the canonical HighlightFx —
# outline plus glow on the overlay layer — at two authored volumes (see the turn_entry_* entries).
func _refresh_cues(entry: Control) -> void:
	if entry == null or not is_instance_valid(entry):
		return
	var acting := int(entry.get_meta("state", ST_READY)) == ST_ACTING
	var inst: Variant = entry.get_meta("inst")
	# ONE "pointed at" state, two directions of gesture: the cursor resting on this entry, and the
	# cursor resting on (or the selection holding) the unit it stands for. They are the same
	# question asked from opposite ends of the screen, so they get the same answer and the same
	# look — the strip and the board are meant to read as one thing (see _sync_marked).
	var hovered: bool = inst == _hovered or inst == _marked
	# Vfx.attach is idempotent per (id, target) and detach on an unattached pair is a no-op, so
	# this is safe to run on every dressing — including from _make_entry, before the entry is in
	# the tree (attach declines a target that isn't, and the next _sync_states brings it back).
	if acting:
		Vfx.attach("turn_entry_acting", entry)
	else:
		Vfx.detach("turn_entry_acting", entry)
	if hovered:
		Vfx.attach("turn_entry_hover", entry)
	else:
		Vfx.detach("turn_entry_hover", entry)
	# ACTING OUTRANKS HOVER by PRECEDENCE, not by magnitude. This used to take the larger of the two
	# factors, which happened to give the right answer only because the acting entry was authored
	# bigger — now that both are tunable, "whose moment it is" must still win a cursor resting on it
	# however the two are set.
	var lift := 1.0
	var secs := LIFT_TIME
	var id := "turn_entry_acting" if acting else ("turn_entry_hover" if hovered else "")
	if not id.is_empty():
		lift = Vfx.param_of(id, "scale", LIFT_ACTING if acting else LIFT_HOVER)
		secs = Vfx.param_of(id, "lift_time", LIFT_TIME)
	_apply_lift(entry, lift, secs)


# The grow itself. NOT HighlightFx.set_grown: that models an on/off state and records a "resting"
# transform on the way in, which cannot express an entry moving between two different lifts (hover
# landing on the acting entry) without sampling a mid-tween scale as its rest — the exact
# accumulate bug set_grown's own comment describes. An entry's rest is known here by construction
# (the list lays them out at scale 1 and never touches scale otherwise), so the factor can be
# tweened straight to, from wherever it currently is, any number of times.
func _apply_lift(entry: Control, factor: float, secs: float = LIFT_TIME) -> void:
	if is_equal_approx(float(entry.get_meta(LIFT_META, 1.0)), factor):
		return
	entry.set_meta(LIFT_META, factor)
	# ONE tween per entry, ever — a second one would fight the first over `scale`.
	if entry.has_meta(LIFT_TWEEN):
		var prev: Variant = entry.get_meta(LIFT_TWEEN)
		if prev is Tween and (prev as Tween).is_valid():
			(prev as Tween).kill()
	# Re-taken each time: the column resizes, and a pivot measured at the old width would swing the
	# entry sideways as it grew.
	entry.pivot_offset = entry.size * 0.5
	# Over the boards it is overflowing onto — an entry that grew UNDER them would just be clipped
	# by its neighbours' cards. Dropped again at rest so the list keeps its natural draw order.
	entry.z_index = HighlightFx.Z_LIFT if factor > 1.0 else 0
	if not entry.is_inside_tree():
		entry.scale = Vector2(factor, factor)
		return
	var tw := entry.create_tween()
	entry.set_meta(LIFT_TWEEN, tw)
	tw.tween_property(entry, "scale", Vector2(factor, factor), secs) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Re-derives every entry's state. Cheap by construction: the compare is an int and the dressing
# only runs on a change, so a strip nobody is looking at costs one loop of integer compares.
func _sync_states() -> void:
	if _rows == null:
		return
	var acting: Unit = screen.acting if screen != null else null
	for child in _rows.get_children():
		var entry := child as Control
		var unit: Unit = entry.get_meta("inst")
		var state := ST_READY
		if unit == acting:
			state = ST_ACTING
		elif _spent(unit):
			state = ST_SPENT
		if int(entry.get_meta("state", -1)) == state:
			continue
		entry.set_meta("state", state)
		_dress(entry, unit, state)


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
		# The pick's ring spans the WHOLE entry — header and picture as one outline, which is what
		# the two of them draw together. Heavier than the border it covers, so it replaces that line
		# instead of doubling it, and costs the thumbnail nothing.
		var ring: DashRing = entry.get_meta("ring")
		ring.position = Vector2.ZERO
		ring.size = Vector2(w, body_h + tab_h)
		ring.set_metrics(
				float(_line_w) * Vfx.param_of("turn_entry_selected", "line_mul", SEL_LINE_MUL),
				w * Vfx.param_of("turn_entry_selected", "dash", SEL_DASH),
				float(RADIUS))
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
	_sync_attention()
	if _forced:
		return
	var area := get_parent() as Control   # the gutter's padding box — the whole visible column
	var rect := area.get_global_rect() if area != null else get_global_rect()
	_set_reading(rect.has_point(get_global_mouse_position()))


# ── Attention arriving from the BOARD ───────────────────────────────────────────
# The other half of the gesture the hover already covers. Pointing at an entry lights the unit;
# pointing at the UNIT — or picking it — now lights its entry, so the player never has to hunt the
# list for the card they are already looking at.
#
# TWO SEPARATE AXES, not one ranked pair. The cursor and the pick are different kinds of fact —
# one is where you are looking this instant, the other is what you have committed to — so they get
# different looks (the transient yellow outline vs. the lasting inverted skin) and they compose:
# picking a unit and then pointing at it shows both at once, which is exactly true of it.
#
# ASKED, not told, like everything else the strip shows. Nothing on the board announces "I am being
# hovered" (the cards would each have to, and a card that was freed mid-hover could not un-announce
# it); the strip simply looks, on the beat it is already awake for. Selection is asked of the one
# authority that owns it (Selection.current), never mirrored here.
func _sync_attention() -> void:
	# The PICK is read even under a harness stand-in: Selection has no cursor in it, so there is
	# nothing for a stand-in to contradict and no reason to freeze it (see mark/point_at).
	_set_selected(Selection.current() as Unit)
	# The cursor half is skipped while a stand-in holds it — with no real mouse over a real slot,
	# unit_at_mouse would answer "nothing" and undo the mark on the very next frame.
	if not _forced:
		_set_marked(screen.unit_at_mouse() if screen != null else null)


# The cursor is on this unit's card: the same cue its entry gets from its own hover (see _refresh_cues).
func _set_marked(unit: Unit) -> void:
	if unit == _marked:
		return
	var was := _entry_for(_marked)
	_marked = unit
	# Both ends of the move, exactly as _set_hovered does it — the cue is derived, so neither call
	# decides anything, it only re-asks.
	_refresh_cues(was)
	_refresh_cues(_entry_for(_marked))


# This unit is the pick: the entry turns inside out. Re-DRESSES rather than re-cueing — the skin is
# the entry's colours, which is _dress's business alone (and _dress re-asks the cues on its way out,
# so nothing is missed).
func _set_selected(unit: Unit) -> void:
	if unit == _selected:
		return
	var was := _entry_for(_selected)
	_selected = unit
	_redress(was)
	_redress(_entry_for(_selected))


# Re-runs an entry's dressing against the facts as they now stand. The state meta is the entry's own
# record (see _sync_states), so this can never disagree with the state it is wearing.
func _redress(entry: Control) -> void:
	if entry == null or not is_instance_valid(entry):
		return
	_dress(entry, entry.get_meta("inst"), int(entry.get_meta("state", ST_READY)))


func _set_reading(on: bool) -> void:
	if on == _reading:
		return
	_reading = on
	_declare_numbers()


# Hands the board the order it should be showing (empty = show nothing). Declared, never pushed:
# the cards derive their own numbers from it, exactly as they do the spotlight.
func _declare_numbers() -> void:
	if screen != null:
		screen.declare_turn_numbers(_order if _reading else [])


# The units currently listed, in turn order — a read for whoever wants to talk about the strip's
# contents (the render harness's turnhover shot) without re-deriving the order.
func listed() -> Array:
	return _order.duplicate()


# Points at a unit as though the cursor had entered its entry (null = point at nothing). The
# harness's door into the hover, and the one place a caller other than the entries themselves
# may move the spotlight. Also stands in for the cursor being over the list, and LATCHES that:
# the harness has no real mouse, so the per-frame hit test would immediately answer "not reading"
# and undo it.
func point_at(unit: Unit) -> void:
	_forced = unit != null
	_set_hovered(unit)
	_set_reading(_forced)


# Marks a unit as though the cursor were resting on its CARD (null = nothing). The harness's door
# into the board-side hover (see _sync_attention), which has no other way in without a real mouse
# over a real slot. LATCHES the same way point_at does, for the same reason.
#
# There is deliberately NO door for the pick: Selection is a real autoload with no mouse in it, so
# the harness selects for real (Selection.select) and the strip reads it exactly as it does in play.
func mark(unit: Unit) -> void:
	_forced = unit != null
	_set_marked(unit)


# The cursor picked a unit out of the list: DECLARE it (the screen owns the declaration, cards
# derive their own look from it — see FightScreen.declare_spotlight). Nothing is pushed at the
# card itself, so the lit unit cannot outlive the hover that lit it.
func _set_hovered(unit: Unit) -> void:
	if unit == _hovered:
		return
	var was := _entry_for(_hovered)
	_hovered = unit
	# Both ends of the move, in this order: the entry losing the cue and the one taking it. Their
	# cues are derived (see _refresh_cues), so nothing here decides what either one looks like.
	_refresh_cues(was)
	_refresh_cues(_entry_for(unit))
	if screen != null:
		screen.declare_spotlight(unit)


# Pressing an entry PRESSES THE UNIT — the list is not a separate control surface with rules of its
# own, it is another place the same units can be reached from. So the press goes to the screen and
# comes out wherever a press on the card itself would have (see FightScreen.press_unit): the
# Interaction session gets first refusal, and picking, inspecting and the move cues all follow
# without this widget knowing what any of them are.
#
# PRESSED HERE AND RELEASED HERE, like any button. The strip stands between two boards people drag
# cards across, and Godot delivers a release to whatever is under the cursor rather than to whoever
# took the press — so acting on the release alone would turn "dropped a unit somewhere near the
# gutter" into "picked whatever entry the cursor happened to be over".
var _pressed_on: Unit = null

func _on_entry_input(event: InputEvent, unit: Unit) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if mb.pressed:
		_pressed_on = unit
		return
	var here := _pressed_on == unit
	_pressed_on = null
	if here and screen != null:
		screen.press_unit(unit)


func _entry_for(unit: Unit) -> Control:
	if unit == null or _rows == null:
		return null
	for child in _rows.get_children():
		var entry := child as Control
		if entry.get_meta("inst") == unit:
			return entry
	return null
