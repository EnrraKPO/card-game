class_name SlotUI
extends Panel

signal pressed
# The move button (see MoveButton) committed — the explicit click/hold entry for repositioning
# a selected fielded unit. The board routes it through the Interaction session (commit_press).
signal move_pressed
# The move button's hover began/ended — the board mounts the landing phantom and declares the
# targeting preview from this slot while it lasts. Hover belongs to the BUTTON alone; the rest
# of the slot is non-interactive dead space during a static fielded selection.
signal move_hover(on: bool)

# WHICH CELL this widget speaks for — one bundled address, not three loose numbers
# (LOCATION_MANAGER_DESIGN.md §2.6). A reference to a board cell, never a store of what
# stands there: occupancy questions go to the world, which is the only thing that knows.
var location: BoardLocation = null
# The combat-wide interaction session (see Interaction): the drop gate and drop commit ask it
# for this slot's ROLE under the current action — the SAME predicate that lit this slot's cue,
# so the visuals and the drop verdict can never disagree. Null outside combat (tooling shots).
var interaction: Interaction = null

var _card_ui: CardUI = null
var _targetable: bool = false   # presentation only (the highlight border) — set via present()
# Cursor-hover during a STATIC moving/placing selection (see CombatBoard's hover tracking):
# a strong white outline on whatever the cursor points at, and — when this slot wears the MOVE
# cue — the arrow bobs while hovered, exactly as it does during a live drag.
var _hovered: bool = false

# ── Slot cue overlay ────────────────────────────────────────────────────────────
# A small icon layer drawn ABOVE any occupant, communicating what this slot means right now:
# it's open to place, a valid spot to reposition onto (ring + a bobbing arrow), or — during a
# targeted spell/ability — a valid (green reticle) or invalid (red X) target. Icons are SVG
# placeholders swappable for PNGs (see BoardGlyphs). The board drives the state; SlotUI just
# renders it. `_targetable` above stays the pure drop-accept gate — the cue is presentation.
enum Cue { NONE, OPEN, MOVE, TARGET_OK, TARGET_BAD }

var _cue: int = Cue.NONE
var _open_hints: bool = false   # while true, empty own slots show the idle "open" marker
var _icon: TextureRect          # the centred glyph (open / ring / reticle / X)
var _arrow: TextureRect         # the reposition arrow, shown above the ring in MOVE cues
var _arrow_top_y: float = 0.0
var _arrow_bottom_y: float = 0.0
var _arrow_tween: Tween
# MOVE-cue composition (set by _apply_icon_geometry, read by the arrow layout): the spot pool's
# top edge and the arrow box side, so the chunky arrow can be parked just above the pool.
var _spot_top: float = 0.0
var _arrow_side: float = 0.0
# The move BUTTON (see MoveButton): a fully self-contained control (its own frame, spot,
# arrow and hold fill) shown INSTEAD of the bare MOVE glyphs on a static, non-click-commit
# destination (set_move_button). It sits at the OPEN marker's exact half-slot box and owns its
# z (above card badges) for life. Any cue change hides it again.
var _move_btn: MoveButton = null
# The attack-target crosshair — an INDEPENDENT overlay (not part of the Cue state machine): it
# marks the enemy a selected/dragged friendly unit will strike, and coexists with that unit's
# own move cues. The red glow that pairs with it rides the target CARD via Vfx (see CombatBoard).
var _attack_icon: TextureRect
# A preview of the unit that would land in THIS slot if the drag were released now (see
# CombatBoard's drag phantom). Rendered as a holographic PROJECTION — cooler, brighter and less
# saturated than the card really is — so it reads clearly apart from the warm, dim, translucent
# ghost the cursor drags (DragGhost.GHOST_TINT). The look is CardUI.set_phantom, the one shared
# "this card isn't real" treatment (a colour transform of the card's own pixels — see
# phantom.gdshader). This used to hand-roll a wash rect here, on the belief that a per-node shader
# blanks the card's clipped, COVER-fit art node; measured, it doesn't. Mounted/unmounted by the board.
var _phantom: CardUI = null

# Translucency is a SEPARATE axis from the phantom colour and stays local: it says how PRESENT the
# projection is, and the answer here is "more present than the see-through drag ghost".
const PHANTOM_ALPHA := 0.9

# The valid-target cue on an OCCUPIED slot: instead of stamping the green reticle glyph over the
# unit, the card itself lights up from within with a warm golden glow (see "target_valid_glow").
# An inner light, chosen so it never collides with the red OUTER menace glow (attack_target_glow)
# or the corner crosshair that may share the same card. Empty valid slots (MANUAL_SLOT spawn spots)
# have no card to light, so they fall back to the reticle glyph. Tracked so we detach from the exact
# card that was lit, even if occupancy shifts before the gesture clears.
const TARGET_VALID_GLOW := "target_valid_glow"
var _glow_card: CardUI = null


# ── Ground state (the world's BoardSlot at this address — SLOT_LAYER_DESIGN.md) ──
# PULL-rendered: the slot widget stores nothing about the ground — it ASKS the world through
# this lookup (installed by CombatBoard) every render_ground() and rebuilds. The house rule:
# a widget keeps only facts it is the authority on, and ground statuses live in the world.
const STATUS_PIP_SCENE := preload("res://scenes/status_pip.tscn")
# ⚠ THE GROUND NEVER PAINTS OVER A PIECE. A unit stands ON the ground; being occluded by it is
# correct, not a bug to route around. Every part of this layer is added BEFORE any occupant, so
# tree order alone keeps the card on top (set_card appends) — the sole exception is a tab's own
# glint, which lifts for the length of its flash (StatusPip.GLINT_Z).
#
# This replaced a full-strength RIM drawn at z2, over the occupant. That rim failed structurally,
# not cosmetically, and the reasons are worth keeping: (1) it claimed the card's EDGE, the most
# contested channel on the board — hover's yellow ring, selection's outline+glow, threat red and
# the acting gold all live there under a documented one-occupant rule, so the ground could only
# ever lose that fight; (2) painting over the occupant sliced card art that overflows the slot;
# and (3) it had to surrender its top edge entirely because it barred across the status tabs.
# All three are the same fault — ground drawn on top of pieces — and it has one fix, not three.
#
# So the ground took the only territory nothing else wants: the GUTTER between slots, plus the
# floor under the card.
#
# The frame claims exactly HALF of each surrounding gap, so two adjacent burning slots meet with no
# seam and a spreading fire reads as ONE FIELD rather than a row of outlined boxes. That continuity
# is the point of the number: a narrower rail was tried and left a channel of bare board between
# neighbours. Half the gap also fits the board's edge slots with no special case — a zone insets its
# grid by CombatBoard.HALF_PAD (8), one pixel more than this reach.
# What stops the wide band fusing with the tabs riding on it is their own outline
# (GroundPalette.tab_border), not a thinner frame.
const GROUND_FRAME_REACH := float(BoardData.SLOT_GAP) * 0.5
# SHARP. A rounded frame was concentric with the slot's own 5px rounding and looked right in
# isolation, but it is the corners that decide whether a fire is one field or four tiles: two
# rounded frames meeting in a gutter leave a notch at every junction, and a burning region reads as
# beads on a string. Square corners tile exactly, edge to edge and corner to corner.
const GROUND_FRAME_RADIUS := 0
# The ground pips ride the slot's TOP BORDER as tabs (StatusPip.as_ground_tab), tucked BEHIND any
# occupant — a card's corners are its busiest real estate, and the ground was competing with them
# there. What keeps the tab readable under a card is the part that rises ABOVE the border: the
# row is raised into the gutter between rows, so the icon's overflow lands in empty gap and
# NEVER reaches the card in the row above. Budgeted against SLOT_GAP because the gutter is a
# constant (it does not scale with the slot); short of it by GROUND_ROW_CLEARANCE so the icon's top
# stops a visible hair from the card above — "almost scraping, never touching".
#
# ⚠ THIS CONSTANT IS THE WHOLE VISIBILITY BUDGET. The strip of a tab that survives an occupant is
# exactly this tall — no more, whatever the icon or band measure — so it is the only number that
# buys visibility on an OCCUPIED slot. Everything else (icon size, band height) only changes what
# is drawn below the card. Taken from 3px of clearance to 2px on the user's "maximize here".
const GROUND_ROW_CLEARANCE := 2.0
const GROUND_ROW_RISE := float(BoardData.SLOT_GAP) - GROUND_ROW_CLEARANCE
# How much of the slot's width ONE tab takes when it is alone. Half the tile was tried and read as
# too broad; this is two thirds of that — wide enough to be a plate rather than a chip, without the
# lone tab looking like a second health bar. Every other count falls out of the equal share below.
const GROUND_TAB_WIDTH_FRAC := 0.347
const GROUND_ROW_INSET := 4.0   # breathing room at each end of the row, inside the slot's width
var ground_lookup: Callable = Callable()   # func() -> BoardSlot (null = ground never touched)
var _ground_frame: Panel = null
var _ground_floor: Panel = null
# The light this ground casts on whoever stands in it — WHITE (a multiply no-op) when there is no
# ground to cast any. Held because occupancy and ground change independently, and whichever moves
# has to be able to re-assert the other's fact without re-querying the world.
var _ground_tint := Color.WHITE
var _ground_pips: HBoxContainer = null
# The sustained ambient VFX currently riding the frame (empty = none), so a status leaving — or
# being replaced by a different one — takes its ambience with it. See _sync_ground_vfx.
var _ground_vfx: PackedStringArray = PackedStringArray()
# The occupant scale the tab row was last laid out FOR — the widget's record of what it drew, not a
# copy of anyone else's state (the card stays the authority; this is only change detection).
var _ground_follow_scale := 1.0


func _ready() -> void:
	custom_minimum_size = Vector2(165, 216)
	_apply_style()
	_build_ground_layer()
	_build_cue_layer()
	mouse_entered.connect(_on_pointer_entered)
	mouse_exited.connect(_on_pointer_exited)


func _build_ground_layer() -> void:
	# The frame: the slot's rect pushed OUT by half a gutter on every side, drawn as a pure BORDER
	# (transparent fill) so the band occupies exactly that overhang and leaves the slot's interior
	# to the floor below it. Everything here sits at z 0 and early in the tree — see the block at
	# the top for why the ground may never climb over its occupant.
	_ground_frame = Panel.new()
	_ground_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ground_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ground_frame.offset_left = -GROUND_FRAME_REACH
	_ground_frame.offset_top = -GROUND_FRAME_REACH
	_ground_frame.offset_right = GROUND_FRAME_REACH
	_ground_frame.offset_bottom = GROUND_FRAME_REACH
	_ground_frame.visible = false
	add_child(_ground_frame)
	_ground_floor = Panel.new()
	_ground_floor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ground_floor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ground_floor.visible = false
	add_child(_ground_floor)
	# NOTE: the ground's LIGHT on its occupant is not a node here at all — it is a tint handed to the
	# card, which multiplies it over its own picture (CardUI.set_ground_tint). It lived here first,
	# as a multiply Panel over the slot's rect, and that shape cannot work: the stat badges overflow
	# the card's rect, so a rect-shaped pass tints them (wrong — they are UI, not scenery) and still
	# cannot cover them fully. The ground says WHAT light falls; the card decides what it lands on.
	_ground_pips = HBoxContainer.new()
	# z 0, and added BEFORE any occupant card (set_card appends): tree order alone puts the card
	# over the tabs, which is the whole point — the ground is UNDER the unit standing on it. A
	# glinting tab lifts itself over that for the length of its flash (StatusPip.GLINT_Z).
	_ground_pips.z_index = 0
	_ground_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE   # the pips answer hover, not the row
	_ground_pips.add_theme_constant_override("separation", 4)
	# Positioned by hand (_layout_ground) rather than anchored: the row is centred on the slot's
	# top edge and must size to its content, which no anchor preset expresses.
	add_child(_ground_pips)


# Re-derives the ground presentation from the world's slot: the gutter frame and the floor wash in
# the (first) status's own colour, its ambient VFX, and one StatusPip per ground status — the same
# pip, tooltip and cue vocabulary units use, so "the ground has a status" reads exactly like "a
# unit has one".
func render_ground() -> void:
	for child in _ground_pips.get_children():
		_ground_pips.remove_child(child)
		child.queue_free()
	var ground: BoardSlot = null
	if ground_lookup.is_valid():
		ground = ground_lookup.call()
	if ground == null or ground.statuses.is_empty():
		_ground_frame.visible = false
		_ground_floor.visible = false
		_ground_tint = Color.WHITE   # no ground, no light — a multiply no-op
		_sync_ground_vfx("")
		_layout_ground()   # clears the row and drops the follow (nothing left to track)
		return
	var first := ground.statuses[0] as StatusInstance
	# The band, drawn as a border on the overhanging rect: a full-width border with a transparent
	# fill IS the ring, with no second rect to keep in sync.
	var fs := StyleBoxFlat.new()
	fs.bg_color = Color(first.data.color, 0.0)
	fs.border_color = GroundPalette.frame(first.data.color)
	fs.set_border_width_all(int(GROUND_FRAME_REACH))
	fs.set_corner_radius_all(GROUND_FRAME_RADIUS)
	fs.anti_aliasing = true
	_ground_frame.add_theme_stylebox_override("panel", fs)
	_ground_frame.visible = true
	# The floor: the slot's own interior, washed. It carries none of the read on its own (an
	# occupant hides nearly all of it) — it exists so the state doesn't stop at a border.
	var gs := StyleBoxFlat.new()
	gs.bg_color = GroundPalette.floor_wash(first.data.color)
	gs.set_corner_radius_all(5)   # matches the slot panel's own radius (_apply_style)
	_ground_floor.add_theme_stylebox_override("panel", gs)
	_ground_floor.visible = true
	_ground_tint = GroundPalette.on_occupant(first.data.color)
	_sync_ground_vfx(first.data.id)   # the tint is pushed by _layout_ground, which every path ends in
	for si: StatusInstance in ground.statuses:
		# stack_display "duplicates" (burning): the pile is shown as ONE TAB PER STACK — the
		# row literally counts the flames — each tab icon-only (`solo`). The default shows one
		# tab wearing the count. Reshaped only once IN the tree: the tab lays its count label
		# out from text metrics, which read near-zero until the node can resolve a theme.
		var duplicates := si.data.stack_display == "duplicates"
		for _i in maxi(si.stacks if duplicates else 1, 1):
			var pip := STATUS_PIP_SCENE.instantiate() as StatusPip
			pip.setup(si)
			_ground_pips.add_child(pip)
			pip.as_ground_tab(duplicates)
	_layout_ground()


# Centres the ground row on the slot's top edge, raised into the row gutter so the tabs' icon
# overflow clears the border (see GROUND_ROW_RISE). When the natural row outgrows the slot
# (a tall pile of duplicate tabs), every tab SHRINKS to an equal share of the slot's width —
# the row never bleeds into the neighbouring column. Re-run on resize.
#
# THE ROW WEARS ITS OCCUPANT'S TRANSFORM. A selected unit grows about its own centre — which, since
# the card is anchored to fill the slot, is the SLOT's centre — and a tab row that stayed put would
# be swallowed by the card climbing over it. So the row takes the same scale about the same pivot,
# and its rise falls out of that for free rather than being a second rule: sitting above the pivot,
# scaling lifts it. What that preserves is the PROPORTION visible above the card's top edge (11px
# of 19 at rest, 11.7 at the authored 1.07) — the tabs read exactly as well grown as resting, at any
# factor. Stated as "match the occupant", not "on selection", so any future grow inherits it.
func _layout_ground() -> void:
	if _ground_pips == null:
		return
	var tabs := _ground_pips.get_children()
	if not tabs.is_empty():
		# Width is a share of the SLOT, never an authored pixel count: a tab is as wide as the space
		# it has, so the row reads the same on any slot size. One tab takes GROUND_TAB_WIDTH_FRAC of
		# the usable width; from two upward the equal share is the smaller number and takes over, so
		# the progression is continuous and the row NEVER bleeds into the neighbouring column.
		var sep := float(_ground_pips.get_theme_constant("separation"))
		var inner := size.x - GROUND_ROW_INSET * 2.0
		var count := float(tabs.size())
		var share := (inner - sep * (count - 1.0)) / count
		# The fraction is of the SLOT's full width, not of `inner` — "half the tile" is the thing the
		# eye actually judges, and the end insets are breathing room rather than part of the measure.
		var per := maxf(floorf(minf(share, size.x * GROUND_TAB_WIDTH_FRAC)), 1.0)
		for t in tabs:
			var pip := t as StatusPip
			if pip != null:
				pip.set_tab_width(per)
	var m := _ground_pips.get_combined_minimum_size()
	_ground_pips.size = m
	# Where the row sits with an unscaled occupant (or none): pinned to the slot's RIGHT edge, a
	# small inset in from it. Right-aligned rather than centred so the row has a fixed end to build
	# from — tabs are appended, so the newest lands at the pinned edge and the pile grows leftward,
	# and nothing already on screen shifts sideways just because the count changed. (A centred row
	# re-centres on every stack, so the whole pile slides half a tab each time the fire ticks.)
	var rest := Vector2(size.x - GROUND_ROW_INSET - m.x, -GROUND_ROW_RISE)
	# ...then the occupant's transform, expressed as a scale about the slot's CENTRE. A Control
	# scales about its own pivot, so the pivot is emulated by placing the row where scaling about
	# the centre would have put its corner: every point of the row then lands exactly where the
	# card's own transform would carry it. Reduces to `rest` at scale 1, so there is no branch.
	var s := _occupant_scale()
	var centre := size * 0.5
	_ground_follow_scale = s
	_ground_pips.scale = Vector2(s, s)
	_ground_pips.position = centre + (rest - centre) * s
	_scale_ground_surfaces(s)
	# ONE owner for the occupant's tint, and it is here rather than in render_ground because
	# occupancy changes WITHOUT the ground changing at all — a unit walking onto burning ground
	# never re-renders it. Every path that alters either fact ends in this function.
	if _card_ui != null and is_instance_valid(_card_ui):
		_card_ui.set_ground_tint(_ground_tint)
	_update_ground_follow()


# The frame and floor ride the occupant's transform along with the tabs — the whole ground layer
# moves as ONE. They used to stay put on the reasoning that terrain does not grow because a unit was
# picked, which was right while the frame was a broad band; a thin rail left behind by its own tabs
# just looks broken. The floor comes along for internal consistency: a frame that steps outward
# while the floor holds still opens a ring of bare slot between them.
# Both rects are CENTRED on the slot's centre already (the frame is the slot grown evenly on every
# side), so scaling about each one's own middle is the same transform the card gets — no position
# arithmetic needed, unlike the tab row, which sits off-centre.
func _scale_ground_surfaces(s: float) -> void:
	var frame_size := size + Vector2(GROUND_FRAME_REACH, GROUND_FRAME_REACH) * 2.0
	_ground_frame.pivot_offset = frame_size * 0.5
	_ground_frame.scale = Vector2(s, s)
	_ground_floor.pivot_offset = size * 0.5
	_ground_floor.scale = Vector2(s, s)
	# (The occupant's tint needs no transform of its own — it rides the card's art node, so it grows
	# and moves with the card by construction.)


# The scale to wear: the occupant's own, read fresh from the card every time. Uniform by
# construction (HighlightFx grows both axes together), so one axis is the whole story.
func _occupant_scale() -> float:
	if _card_ui == null or not is_instance_valid(_card_ui):
		return 1.0
	return maxf(_card_ui.scale.x, 0.01)


# The follow has to be CONTINUOUS, not endpoint-synced: the grow tween is TRANS_BACK and overshoots
# past its target before settling, so a row that only learned the final scale would visibly lag and
# then snap. Polling is a pure pull — the card stays the authority and this stores nothing but what
# it last drew — and it costs a float compare on the slots that actually have tabs to move.
func _update_ground_follow() -> void:
	set_process(_card_ui != null and _ground_frame != null and _ground_frame.visible)


func _process(_delta: float) -> void:
	if not is_equal_approx(_occupant_scale(), _ground_follow_scale):
		_layout_ground()


# ── The ground's third voice: motion ────────────────────────────────────────────────────────────
# The frame and floor say the ground IS something; the stream says it is DOING it. Motion is the
# one channel on the board with no other claimant, and it is the only one that still reads when a
# card covers the slot outright — because sparks are DELIBERATELY exempt from the occlusion rule
# above (user's call, and the right one: fire that stops at a card's edge isn't fire). The emit
# behavior draws on the overlay layer, above the board, so they fly wherever they like for free.
#
# CONVENTION, not a burning special case. A ground status animates through up to three library
# entries, each optional and independently gated:
#   ground_<status_id>         — the ambient PARTICLES (burning: sparks thrown off the ground)
#   ground_<status_id>_haze    — the ambient FIELD (burning: the air over it, distorted)
#   ground_<status_id>_flare   — the punctuation, fired with a pip's glint
# Two ambient voices because one was never enough: motion that draws objects and motion that
# doesn't are different statements, and a fire makes both. Authoring these is the whole cost of
# giving the next ground status its motion — frost would write `_haze` as a cold blur and skip the
# particles; a status with none of the three simply sits still.
const GROUND_AMBIENCE := ["", "_haze"]


static func ground_vfx_id(status_id: String, suffix: String = "") -> String:
	return "ground_%s%s" % [status_id, suffix]


static func ground_flare_id(status_id: String) -> String:
	return ground_vfx_id(status_id, "_flare")


# Attaches `status_id`'s ambient voices to the frame, detaching whatever was riding it before.
# Idempotent: re-rendering an unchanged ground (which happens on every board refresh) must not
# restart them, or a burning slot would flicker its way through the whole fight.
func _sync_ground_vfx(status_id: String) -> void:
	var want := PackedStringArray()
	if not status_id.is_empty():
		for suffix: String in GROUND_AMBIENCE:
			var id := ground_vfx_id(status_id, suffix)
			if Vfx.live(id):   # unauthored voices are simply absent, never a warning
				want.append(id)
	if want == _ground_vfx:
		return
	for id: String in _ground_vfx:
		if not want.has(id):
			Vfx.detach(id, _ground_frame)
	if _ground_frame.is_inside_tree():
		for id: String in want:
			if not _ground_vfx.has(id):
				Vfx.attach(id, _ground_frame)
	_ground_vfx = want


# The loud half of the ground's motion, fired in concert with a tab's glint (see VFXPlayer's
# ground arrival and LivePresenter.show_ground_results): the same sparks the ambience emits, in a
# burst. One vocabulary, two volumes — the shape hover and the turn spotlight already share.
func flare_ground(status_id: String) -> void:
	if _ground_frame == null or not _ground_frame.is_inside_tree():
		return
	var id := ground_flare_id(status_id)
	if Vfx.live(id):
		Vfx.play(id, _ground_frame)


# All this ground row's tabs for `status_id`, in row order. The damage moment glints the WHOLE
# fire at once (every flame acts together — see LivePresenter.show_ground_results), so the
# presenter needs the full set, not one pip.
func ground_pips_of(status_id: String) -> Array:
	var out: Array = []
	for child in _ground_pips.get_children():
		var pip := child as StatusPip
		if pip != null and pip.status != null and pip.status.data.id == status_id:
			out.append(pip)
	return out


# The LAST match: with duplicate-display statuses several tabs share an id, and the newest tab
# (the freshest stack) is the one a flash should land on.
func find_ground_pip(status_id: String) -> StatusPip:
	var matches := ground_pips_of(status_id)
	if matches.is_empty():
		return null
	return matches[matches.size() - 1] as StatusPip


# The `index`-th tab (spread rolls glint the pile in order), clamped to the last one standing —
# a flame that faded mid-pass removed its tab while later rolls in the snapshot were still due.
func ground_pip_at(status_id: String, index: int) -> StatusPip:
	var matches := ground_pips_of(status_id)
	if matches.is_empty():
		return null
	return matches[clampi(index, 0, matches.size() - 1)] as StatusPip


# ── The pointer ring ────────────────────────────────────────────────────────────
# THE SLOT ANSWERS ONLY WHILE IT IS EMPTY. The rule for the board is "outline whatever the pointer is
# actually addressing", and an occupied slot is not that — the thing you mean is the unit standing in
# it, and its card wears the ring itself (see CardUI._apply_hover_outline). An EMPTY slot is the
# thing you mean, a place to put something, and it was the one board surface that answered a cursor
# with nothing at all.
#
# `mouse_entered` is trustworthy here in a way it is not for a lifting hand card: a slot is furniture,
# it never moves out from under the pointer, so there is no oscillation to hit-test around.
var _pointer_in := false

func _on_pointer_entered() -> void:
	_pointer_in = true
	_apply_hover_outline()


func _on_pointer_exited() -> void:
	_pointer_in = false
	_apply_hover_outline()


# Derived from both facts every time, never toggled from one: a unit placed into (or killed out of)
# the slot the cursor happens to be resting on hands the ring over without either side noticing the
# other. Called from set_card/clear_card for exactly that.
func _apply_hover_outline() -> void:
	HoverFx.apply(self, _pointer_in and _card_ui == null and HoverFx.available())


func set_targetable(enabled: bool) -> void:
	_targetable = enabled
	_apply_style()


func _apply_style() -> void:
	# Deliberately NOT ScreenUI.SURFACE_DEEP — that's an app-chrome tone (now light, to match the
	# app's plastic-toy palette), but an empty battlefield slot is the game board, not UI chrome; it
	# needs to stay a dark, receding "empty" surface so cards read clearly against it either way.
	# Still themeable via ScreenUI.SLOT_* (backed by UIPalette's own "Combat board" group).
	var style := StyleBoxFlat.new()
	style.bg_color = ScreenUI.SLOT_EMPTY
	if _hovered:
		# The pointing-at-it read outranks the other borders while it lasts.
		style.set_border_width_all(5)
		style.border_color = Color.WHITE
	elif _targetable:
		style.set_border_width_all(3)
		style.border_color = ScreenUI.SLOT_BORDER_HIGHLIGHT
	else:
		style.set_border_width_all(1)
		style.border_color = ScreenUI.SLOT_BORDER_IDLE
	style.set_corner_radius_all(5)
	add_theme_stylebox_override("panel", style)


# ── Cue overlay ─────────────────────────────────────────────────────────────────

func _build_cue_layer() -> void:
	_icon = TextureRect.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.z_index = 1               # above any occupant card (which draws at z 0)
	_icon.visible = false
	add_child(_icon)

	_arrow = TextureRect.new()
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.texture = BoardGlyphs.tex("move_arrow")
	_arrow.z_index = 1
	_arrow.visible = false
	add_child(_arrow)

	_attack_icon = TextureRect.new()
	_attack_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_attack_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_attack_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_attack_icon.texture = BoardGlyphs.tex("attack")
	_attack_icon.z_index = 3        # above the cue glyphs AND any phantom
	_attack_icon.visible = false
	add_child(_attack_icon)

	_move_btn = MoveButton.new()
	_move_btn.visible = false
	_move_btn.commit_requested.connect(func() -> void: move_pressed.emit())
	_move_btn.hover_changed.connect(func(on: bool) -> void: move_hover.emit(on))
	add_child(_move_btn)

	_layout_cue()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _icon != null:
		_layout_cue()


# The round glyphs (ring / reticle / X) sit in a centred square this fraction of the slot's
# shorter side. The OPEN marker is the exception — it fills half the slot to echo its shape.
const ICON_FACTOR := 0.44

# MOVE cue ("reposition here") composition. The spot is a foreshortened ellipse — a spotlight pool
# seen in perspective — biased toward the slot's lower edge, with the chunky arrow bobbing just
# above it. All relative to the slot so it reads at any board scale.
const SPOT_W := 0.58          # pool width as a fraction of the slot width
const SPOT_ASPECT := 0.30     # pool height / width — very slender, a strong perspective foreshorten
const ARROW_W := 0.46         # arrowhead box side as a fraction of the pool width
const ARROW_GAP := 0.30       # gap between arrowhead base and pool, as a fraction of pool height
const SPOT_BIAS := 0.06       # nudge the whole composition down so the pool hugs the lower edge
const MOVE_CUE_ALPHA := 0.85  # the whole move cue rides a touch of transparency so it reads as a
							  # gentle, non-intrusive hint rather than a bright call to attention


# Sizes/positions the glyphs relative to the slot's current size (combat resizes slots to fill
# the board), so the cue reads at any board scale. Keeps the MOVE arrow's bob endpoints current.
func _layout_cue() -> void:
	_apply_icon_geometry()   # sets the pool box AND, for MOVE, _spot_top / _arrow_side
	_layout_arrow()          # size/position the arrow relative to the pool just laid out
	if _move_btn != null:
		var box := _open_box()
		_move_btn.position = box.position
		_move_btn.size = box.size
	if _arrow_tween == null or not _arrow_tween.is_valid():
		_arrow.position.y = _arrow_top_y
	elif _cue == Cue.MOVE:
		_restart_arrow_bob()   # endpoints moved — rebuild the loop around them

	_position_attack_icon()
	_fit_phantom()
	_layout_ground()


# Sizes the arrow and sets its bob endpoints from the pool position (_spot_top) computed by
# _apply_icon_geometry — so it always parks its base just above the current pool. Must run AFTER
# _apply_icon_geometry, since a stale _spot_top (e.g. from the NONE state) would fling it off-slot.
func _layout_arrow() -> void:
	var s := size
	var a := _arrow_side if _cue == Cue.MOVE else minf(s.x, s.y) * 0.24
	_arrow.size = Vector2(a, a)
	_arrow.position.x = (s.x - a) * 0.5
	_arrow_top_y = _spot_top - a               # parked, base sitting just above the pool
	_arrow_bottom_y = _arrow_top_y + a * 0.28  # a gentle dip toward the pool


# The attack crosshair COMPOSES with any centre cue instead of colliding with it — a slot can show
# several states at once. Alone, the crosshair sits centred (the classic "this is the target"
# read). When a centre glyph is ALSO up (e.g. the green autocast reticle on an enemy that is also
# this unit's auto-attack target), it shrinks into the top-right corner so both states read
# together. Driven from set_cue / set_attack_marker / _layout_cue so it re-solves on any change.
func _position_attack_icon() -> void:
	var s := size
	var m := minf(s.x, s.y)
	if _icon.visible:
		var xs := m * 0.34
		_attack_icon.size = Vector2(xs, xs)
		_attack_icon.position = Vector2(s.x - xs - m * 0.05, m * 0.05)
	else:
		var xs := m * 0.52
		_attack_icon.size = Vector2(xs, xs)
		_attack_icon.position = Vector2((s.x - xs) * 0.5, (s.y - xs) * 0.5)


# The centred glyph's box depends on the cue: OPEN fills half the slot (stretched to the slot's
# own portrait shape), the round glyphs stay a centred aspect-locked square.
# The OPEN marker's box — half the slot's size, echoing its shape, centred. Shared by the OPEN
# cue glyph and the move button (the button IS the open rect, promoted to a control).
func _open_box() -> Rect2:
	var s := size
	return Rect2(s.x * 0.25, s.y * 0.25, s.x * 0.5, s.y * 0.5)


func _apply_icon_geometry() -> void:
	var s := size
	if _cue == Cue.OPEN:
		_icon.stretch_mode = TextureRect.STRETCH_SCALE
		var box := _open_box()
		_icon.size = box.size
		_icon.position = box.position
	elif _cue == Cue.MOVE:
		# Spotlight pool (foreshortened ellipse) + the chunky arrow above it, laid out as one
		# vertically-centred composition — with the arrow up top, the pool naturally lands in the
		# lower half; SPOT_BIAS nudges it a touch further toward the slot's bottom edge.
		_icon.stretch_mode = TextureRect.STRETCH_SCALE
		var w := s.x * SPOT_W
		var h := w * SPOT_ASPECT
		_arrow_side = w * ARROW_W
		var gap := h * ARROW_GAP
		var total := _arrow_side + gap + h
		var top := (s.y - total) * 0.5 + s.y * SPOT_BIAS
		_spot_top = top + _arrow_side + gap
		_icon.size = Vector2(w, h)
		_icon.position = Vector2((s.x - w) * 0.5, _spot_top)
	else:
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var side := minf(s.x, s.y) * ICON_FACTOR
		_icon.size = Vector2(side, side)
		_icon.position = Vector2((s.x - side) * 0.5, (s.y - side) * 0.5)


# `animated` bobs the reposition arrow (a live drag); false parks it (a static selection).
func set_cue(cue: int, animated: bool = false) -> void:
	_cue = cue
	_stop_arrow_bob()
	# Structural: ANY cue change retires the move button (cancelling an in-flight hold); the
	# board re-raises it after the MOVE cue when the action wants it (see set_move_button).
	set_move_button(false)
	# Any cue change ends the previous valid-target glow; the TARGET_OK branch re-lights it if it
	# still applies. Idempotent (Vfx de-dupes), so a TARGET_OK→TARGET_OK refresh doesn't churn.
	_clear_valid_glow()
	_apply_icon_geometry()   # glyph box depends on the cue (OPEN fills half the slot)
	# Only the move cue is deliberately softened; the other glyphs stay at full strength.
	_icon.modulate = Color(1.0, 1.0, 1.0, MOVE_CUE_ALPHA) if cue == Cue.MOVE else Color.WHITE
	_arrow.modulate = Color(1.0, 1.0, 1.0, MOVE_CUE_ALPHA)
	match cue:
		Cue.OPEN:
			_icon.texture = BoardGlyphs.tex("open")
			_icon.visible = true
			_arrow.visible = false
		Cue.MOVE:
			_icon.texture = BoardGlyphs.tex("move_ring")
			_icon.visible = true
			# The arrow belongs to MOTION: a live drag (animated) or a hover on a static
			# selection (set_hovered) shows it bobbing; a resting static cue is just the
			# spotlight pool. Geometry is laid out either way so the arrow can appear on
			# hover without the pool shifting.
			_arrow.visible = animated
			_layout_arrow()   # _apply_icon_geometry (above) just set _spot_top — place the arrow to it
			_arrow.position.y = _arrow_top_y
			if animated:
				_restart_arrow_bob()
		Cue.TARGET_OK:
			# An occupied valid target lights the CARD from within (golden inner glow) rather than
			# stamping the reticle over it; an empty valid slot (MANUAL_SLOT spawn spot) has nothing
			# to light, so it keeps the reticle glyph.
			if _card_ui != null:
				_light_valid_glow()
				_icon.visible = false
			else:
				_icon.texture = BoardGlyphs.tex("target_ok")
				_icon.visible = true
			_arrow.visible = false
		Cue.TARGET_BAD:
			_icon.texture = BoardGlyphs.tex("target_bad")
			_icon.visible = true
			_arrow.visible = false
		_:
			_icon.visible = false
			_arrow.visible = false
	_position_attack_icon()   # a centre glyph appearing/leaving moves the crosshair to compose


# Returns the slot to its resting look: the "open" marker on an empty own slot while placement
# hints are on, otherwise nothing. Called whenever a targeting/move gesture ends or occupancy
# changes.
func reset_cue() -> void:
	if _open_hints and _card_ui == null and location != null and location.side == 0:
		set_cue(Cue.OPEN)
	else:
		set_cue(Cue.NONE)


# Raises/retires the move button on a MOVE-cue slot — called by the board's _present_slot for
# static, non-click-commit DESTINATIONS (a selected fielded unit's landing spots). The button
# REPLACES the bare MOVE glyphs (it renders its own spot+arrow inside its frame); hiding it
# cancels any in-flight hold and releases its hover (MoveButton's visibility notification).
func set_move_button(on: bool) -> void:
	if _move_btn == null:
		return
	var show := on and _cue == Cue.MOVE
	if show:
		_icon.visible = false
		_arrow.visible = false
	if _move_btn.visible == show:
		return
	_move_btn.visible = show
	if show:
		var box := _open_box()
		_move_btn.position = box.position
		_move_btn.size = box.size


func set_open_hints(enabled: bool) -> void:
	_open_hints = enabled
	reset_cue()


# Cursor-hover presentation during a static moving/placing selection: the strong white outline,
# plus — on a MOVE-cue slot — the arrow APPEARING and bobbing while hovered (the same animation
# a live drag shows; the resting static cue is spotlight-only). Driven by CombatBoard's hover
# tracking; reversible and cue-preserving.
func set_hovered(on: bool) -> void:
	if on == _hovered:
		return
	_hovered = on
	_apply_style()
	if _cue == Cue.MOVE:
		_arrow.visible = on
		if on:
			_restart_arrow_bob()
		else:
			_stop_arrow_bob()
			_arrow.position.y = _arrow_top_y


# Lights the current occupant from within as a valid target (golden inner glow). Tracks the exact
# card lit so _clear_valid_glow detaches from that node even if the slot's occupant later changes.
func _light_valid_glow() -> void:
	if _card_ui == null or _card_ui == _glow_card:
		return
	_clear_valid_glow()
	_glow_card = _card_ui
	Vfx.attach(TARGET_VALID_GLOW, _glow_card)


func _clear_valid_glow() -> void:
	if _glow_card != null and is_instance_valid(_glow_card):
		Vfx.detach(TARGET_VALID_GLOW, _glow_card)
	_glow_card = null


func _restart_arrow_bob() -> void:
	_stop_arrow_bob()
	_arrow.position.y = _arrow_top_y
	_arrow_tween = create_tween().set_loops()
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_bottom_y, 0.65) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_top_y, 0.65) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_arrow_bob() -> void:
	if _arrow_tween != null and _arrow_tween.is_valid():
		_arrow_tween.kill()
	_arrow_tween = null


# Shows/hides the red attack-target crosshair over this slot's occupant. Independent of the cue
# state — the board turns it on for the enemy a selected/dragged friendly unit will strike.
func set_attack_marker(enabled: bool) -> void:
	_attack_icon.visible = enabled
	if enabled:
		_position_attack_icon()   # centred alone, cornered when a centre cue shares the slot


# Mounts the landing PROJECTION of the unit that would drop here on release (drag phantom), or
# clears it when `ghost` is null. Display-only — it never intercepts input.
func mount_phantom(ghost: CardUI) -> void:
	unmount_phantom()
	_phantom = ghost
	if ghost == null:
		return
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.z_index = 0
	ghost.modulate = Color(1.0, 1.0, 1.0, PHANTOM_ALPHA)
	add_child(ghost)   # facing derives from the slot on reparent (CardUI NOTIFICATION_PARENTED)
	ghost.custom_minimum_size = Vector2.ZERO
	ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ghost.set_phantom(true)


func _fit_phantom() -> void:
	if _phantom != null and is_instance_valid(_phantom):
		_phantom.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func unmount_phantom() -> void:
	if _phantom != null and is_instance_valid(_phantom):
		if _phantom.get_parent() == self:
			remove_child(_phantom)
		_phantom.queue_free()
	_phantom = null


func get_card() -> CardUI:
	return _card_ui


func set_card(card: CardUI) -> void:
	if _card_ui != null and _card_ui.get_parent() == self:
		remove_child(_card_ui)
	_card_ui = card
	_apply_hover_outline()   # occupancy decides who wears the ring (see _apply_hover_outline)
	if card == null:
		reset_cue()   # emptied — may show the idle "open" marker again
		_layout_ground()   # no occupant to follow: the row drops back to its resting place
		return
	# Clear old parent slot's reference before re-parenting
	var old_parent := card.get_parent()
	if old_parent is SlotUI:
		var old_slot := old_parent as SlotUI
		old_slot._card_ui = null
		if card.pressed.is_connected(old_slot._on_card_pressed):
			card.pressed.disconnect(old_slot._on_card_pressed)
		old_slot.remove_child(card)
		# The vacated slot re-derives its resting look (idle OPEN marker on an empty own slot)
		# like every other emptying path — without this, a click-move (which resets the board
		# BEFORE committing) leaves the old slot bare until the next full present.
		old_slot.reset_cue()
	elif old_parent != null:
		old_parent.remove_child(card)
	add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The card is anchored to fill this slot — clear its own minimum size so the anchors really
	# drive it. A carried-over minimum (the hand's card size, or card_ui.tscn's default on a King
	# placed directly) would overrule the anchors and overflow any slot smaller than it.
	card.custom_minimum_size = Vector2.ZERO
	# Becoming a board occupant sheds hand-bound presentation (play-me glow / dim / selection
	# tint) — hand states are re-derived by the Hand for cards IN the hand; a card that left
	# can't truthfully wear them, and nobody else is positioned to clear them.
	card.shed_hand_state()
	# CardUI._gui_input calls accept_event() on every click release (long-press/tooltip handling),
	# which marks the event handled and stops it from ever bubbling to this slot's own _gui_input —
	# MOUSE_FILTER_PASS doesn't help, since Godot only forwards an event to the parent if the child
	# left it unhandled. So we listen to the card's `pressed` signal directly instead of relying on
	# GUI event propagation (see Combat._on_board_slot_pressed, the click-to-open-ability-tray path).
	if not card.pressed.is_connected(_on_card_pressed):
		card.pressed.connect(_on_card_pressed)
	# Facing is DERIVED from which side's slot holds the card (CardUI's NOTIFICATION_PARENTED
	# hook fired during add_child above): player cards keep the authored orientation, enemy
	# cards mirror so the two armies read as mirror images across the board.
	reset_cue()   # now occupied — clear any lingering open/move marker
	# A card can arrive ALREADY GROWN (a selected unit repositioned onto this slot), so the row
	# takes its transform now rather than waiting for the next scale change to notice.
	_layout_ground()


func _on_card_pressed() -> void:
	pressed.emit()


func clear_card() -> CardUI:
	var card := _card_ui
	# The light stops when the unit steps out of it. Only this path needs to say so — a card moving
	# to another SLOT is re-dressed by that slot's own layout, but one leaving the board entirely
	# (picked up, killed) has nobody left to speak for it and would carry the fire's colour away.
	if card != null and is_instance_valid(card):
		card.set_ground_tint(Color.WHITE)
	if _card_ui != null and _card_ui.get_parent() == self:
		remove_child(_card_ui)
	if card != null and card.pressed.is_connected(_on_card_pressed):
		card.pressed.disconnect(_on_card_pressed)
	_card_ui = null
	_apply_hover_outline()   # now empty: if the cursor is still here, the slot takes the ring
	reset_cue()   # emptied — may show the idle "open" marker again
	# A unit can leave MID-GROW (picked up, then moved): the row must return to rest rather than
	# stay stretched for the occupant that walked away.
	_layout_ground()
	return card


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			pressed.emit()
			accept_event()


# The drop gate = "what is my ROLE under the current action?" — asked of the Interaction
# session, which is the same authority that lit this slot's cue. The role also feeds the drag
# ghost's verdict (DESTINATION → the unit copy, TARGET_VALID/INVALID → the cast views; the
# ghost's own no-ability fallback keeps spell drags on the plain copy).
func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if not (data is CardUI):
		return false
	if interaction == null:
		return false
	# The live action must be ABOUT the card being dragged. A foreign payload gets no verdict at
	# all — not even an invalid one: reporting nothing leaves the ghost on its default view, which
	# is the honest reading of "this slot is not answering you."
	if not interaction.owns_drag(data):
		return false
	match interaction.role_of(self):
		Interaction.Role.DESTINATION:
			DragGhost.report(DragGhost.State.UNIT, self)
			return true
		Interaction.Role.TARGET_VALID:
			DragGhost.report(DragGhost.State.CAST_OK, self)
			return true
		Interaction.Role.TARGET_INVALID:
			DragGhost.report(DragGhost.State.CAST_INVALID, self)
			return false
		_:
			return false


func _drop_data(_at: Vector2, data: Variant) -> void:
	if interaction != null:
		# Re-validates the payload's identity AND the role via the same predicates that lit the
		# cue, then commits.
		interaction.commit_drop(self, data)
