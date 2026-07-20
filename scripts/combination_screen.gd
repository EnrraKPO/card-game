extends Control

# The CRAFTING screen (map "forge" nodes) — a diegetic alchemy-room: no Shell chrome, the exit is an
# in-world door button on the left rail, and the dressing comes from EnvArt("crafting", ...) slots.
# Layout: [card table over a bottom strip (door + charm row)] · [alchemy station].
# COMBINE two deck cards into one, or ENCHANT a card with a charm. Both actions share the
# station column (slot A + slot B → result + action button) and support two input styles:
#  • Tap/click: tap a card into slot A, a second into slot B → Combine. Or tap a charm (it goes to
#    slot A), then tap a card (slot B) → Enchant. Tapping a filled slot clears it.
#  • Drag: drag a card onto another (combine), or a charm onto a card (enchant); the dragged item
#    and the hovered target fill the slots live for the preview. Dropping a CARD just APPOINTS the
#    pair into slot A/B — same as tapping them one at a time — so the station's Combine button is
#    still the one destructive commit point. Dropping a CHARM applies directly (it just spends the
#    charm; non-destructive, no confirmation needed). While dragging, the floating item carries a
#    particle aura and a vortex links it to a valid target (VFX in ForgeFX).
# On a touch device a dragged charm lifts above the finger (which would otherwise hide it), with the
# hit-test following the chip; on desktop it stays centred on the cursor at its normal size.

# One entry per deck card: { "card": DeckCard, "deck_idx": int, "data": CardData, "ui": CardUI,
# "item": ForgeDragItem (null for non-combinable cards, which can't be dragged but can be enchanted) }
var _entries: Array = []

# Must match the CardUI root custom_minimum_size in scenes/card_ui.tscn so the deck grid scales.
const CARD_SIZE := Vector2(160, 210)
# Native card aspect (260×340) — _fit_cards sizes the table grid with it.
const CARD_ASPECT := 340.0 / 260.0
# All particle VFX tuning lives in ForgeFX (ForgeFX.AURA / ForgeFX.LINK).

const OK_COLOR   := Color(0.4, 1.0, 0.55)
const BAD_COLOR  := Color(1.0, 0.4, 0.4)
const WARN_COLOR := Color(1.0, 0.6, 0.3)
const IDLE_COLOR := Color(0.7, 0.7, 0.8)

const DRAG_THRESHOLD := 12.0   # px the pointer must travel before a press becomes a drag (vs a tap)
# The deck grid's BASE gap. _fit_cards inflates the live separations above this to absorb the
# fit remainder — never read the separation back from the grid (it returns the inflated value).
const GRID_SEP := 16.0

var _deck_grid: GridContainer
var _scroll: ScrollContainer
var _charm_col: HBoxContainer
var _card_size := CARD_SIZE
const CHARM_SIZE := Vector2(82, 82)   # scaled with SHELF_H so chips still fit the shelf's shorter interior

# Bottom strip (door + charm shelf over a wallpaper backdrop) — ALL fixed constants (user
# directive): this footprint never changes with deck size or window size, and never eats into
# the card scroll's space above it (the scroll just gets whatever's left, same as always).
var _door: TextureButton
var _shelf: Control
const DOOR_ASPECT := 512.0 / 768.0   # door.svg's native w/h
const STRIP_H := 221.0               # the door's fixed height (may bleed past the window on short screens); 15% smaller than the original 260 to give the card scroll more room
const WALLPAPER_H := 161.5           # between SHELF_H and STRIP_H, bottom-anchored under the door
const SHELF_H := 110.5               # roughly half the door's height
# The shelf sits centred on the WALLPAPER's span (not the door's full height) — precomputed as a
# fixed top margin from the strip's own top edge.
const SHELF_TOP_MARGIN := STRIP_H - WALLPAPER_H + (WALLPAPER_H - SHELF_H) * 0.5

# Station column: two ingredient slots, the result (card + name + full description), a status line,
# the Mineral balance and the Combine button.
var _slot_a: Control
var _slot_b: Control
var _result_slot: Control
var _result_info: VBoxContainer
var _result_text_box: Control
var _ability_strip: HBoxContainer
var _mineral_value: Label
var _preview_status: Label
var _combine_btn: Button

# Click-to-select flow (the no-drag path): entry indices of the chosen pair (-1 = empty).
var _sel_a: int = -1
var _sel_b: int = -1
# Click-selected charm to enchant with ("" = none). When set, the screen is in ENCHANT mode:
# slot A shows the charm, the next tapped card (kept in _sel_a) is the target.
var _sel_charm: String = ""
# The card-shaped slot size (used to size the charm chip shown in a slot). Set in _build_ui.
var _slot_size := Vector2.ZERO
# A press not yet resolved: it becomes a TAP (select) on release, or a DRAG once it moves past
# DRAG_THRESHOLD — so a click selects while dragging still works.
var _pending: Dictionary = {}
var _press_pos := Vector2.ZERO

# Drag session (empty `_drag` == nothing in flight).
var _overlay: Control
var _drag: Dictionary = {}
var _follower: Control = null
var _follower_visual: Control = null   # the card/charm visual inside the follower (wobbles when linked)
var _follower_base_pos := Vector2.ZERO # its resting position (centred on the pointer)
var _follower_center := Vector2.ZERO   # visual centre offset from the pointer (0 for cards; lifted for charms)
var _wob_t := 0.0
var _wob := 0.0                         # eased 0→1 wobble strength (ramps with the connection)
var _aura: ForgeAura = null
var _target_aura: ForgeAura = null
var _target_item: Control = null       # the hovered target card's wrapper (wobbles while linked)
# The swirling vortex that connects the two cards while hovering a valid target.
var _link: ForgeLink = null
var _hover_idx: int = -1
# Carried from a valid combine hover so the drop doesn't recompute.
var _result_deck_card: DeckCard = null
# The in-scene fusion overlay (null when closed) — the input-blocking backdrop the Combine button's
# fusion animation + result toast play out over (see _start_panel_fusion / _begin_fusion).
var _combine_modal: Control = null
# The merge VFX painted over slots A+B while a valid combine is previewed (visual only — no drone).
# _panel_fx_key identifies the shown pair so a rebuilt panel only respawns the FX when it changes.
var _panel_fx: ForgeMergeFX = null
var _panel_fx_key := ""
# Fusion-animation state, live only between hitting "Combine" and dismissing the result toast. While
# _fusing is true the modal dim ignores clicks/Esc so the sequence can't be cut off mid-flight.
var _fusing := false
var _fuse_anim: ForgeFuseAnim = null


func _ready() -> void:
	Sfx.music("music_forge")
	_build_ui()
	_rebuild_deck()
	_rebuild_charms()
	_refresh_forge()


func get_chrome() -> Dictionary:
	# Diegetic room: no Shell chrome at all. The left-rail door button is the visible exit; the OS
	# back gesture / Esc still leaves via `back`. Mineral (the only run stat that matters here)
	# renders at the station instead of a header chip.
	return {"show_header": false, "show_footer": false, "back": _leave}


func _exit_tree() -> void:
	# The mixing loop lives on the Sfx AUTOLOAD, so it survives this screen being freed — leaving
	# mid-drag (Shell frees content on navigation, no _cancel_drag runs) would otherwise let the
	# drone play forever over the next screen.
	Sfx.mixing_stop()


func _build_ui() -> void:
	_card_size = CARD_SIZE   # refined by _fit_cards on layout

	# ── Table surface: full-bleed environment art behind everything ──────────────
	var bg := TextureRect.new()
	bg.texture = EnvArt.tex("crafting", "table_bg")
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(bg)

	# ── Body: [charm shelf + door] · [card table] · [alchemy station] ────────────
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)   # keep content off the table's rim art
	add_child(pad)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	pad.add_child(body)

	# Left column: the card table with a bottom strip under it — the exit door in the corner, the
	# charm shelf as a horizontal row. The strip sits in the grid's natural remainder (fit-all cards
	# rarely divide the height evenly), so the charms cost the table almost nothing. Everything on
	# it is a drag SOURCE or the exit — never a drop target — so a flicked drag can't end there.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	left.size_flags_vertical   = SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 2.37
	left.add_theme_constant_override("separation", 14)
	body.add_child(left)

	# The card table — the whole deck, fit-to-space (see _fit_cards).
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	# SHOW_NEVER (not DISABLED): the fitted grid's min width must NOT propagate up, or it deadlocks
	# the HBox into pushing the station off-screen after _fit_cards sizes the cards.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.resized.connect(_fit_cards)
	left.add_child(scroll)
	_scroll = scroll

	# Bottom strip: door + charm row over a wallpaper backdrop — a FIXED-height band (user
	# directive: this footprint never resizes with deck count or window size, and never eats into
	# the card scroll above it; the scroll just gets whatever's left, exactly like any other row in
	# this VBox). `strip_layer` is a plain (non-Container) Control so the wallpaper and the strip
	# itself can freely OVERLAP as two full-rect anchored layers, wallpaper behind.
	var strip_layer := Control.new()
	strip_layer.custom_minimum_size.y = STRIP_H
	left.add_child(strip_layer)

	# The wallpaper backdrop spans the FULL pad width (not just the left/card-table column) so it
	# continues underneath the station panel — the station's opaque background then covers its
	# right portion, reading as one continuous stripe running behind both columns. `pad` is a
	# MarginContainer, which force-fits any direct child to its whole rect (ignoring anchors) — so
	# the anchored bottom-band wallpaper needs a plain (non-Container) full-rect Control between
	# them, same trick as `strip_layer` above. Inserted behind `body` so the station draws over it.
	var backdrop_layer := Control.new()
	pad.add_child(backdrop_layer)
	pad.move_child(backdrop_layer, 0)

	var wallpaper := TextureRect.new()
	wallpaper.texture = EnvArt.tex("crafting", "wall_stripe")
	wallpaper.stretch_mode = TextureRect.STRETCH_TILE
	wallpaper.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wallpaper.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	wallpaper.mouse_filter = MOUSE_FILTER_IGNORE
	wallpaper.anchor_left = 0.0
	wallpaper.anchor_right = 1.0
	wallpaper.anchor_top = 1.0
	wallpaper.anchor_bottom = 1.0
	wallpaper.offset_top = -WALLPAPER_H
	wallpaper.offset_bottom = 0.0
	backdrop_layer.add_child(wallpaper)

	var strip := HBoxContainer.new()
	strip.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	strip.add_theme_constant_override("separation", 14)
	strip_layer.add_child(strip)

	var door := TextureButton.new()
	door.texture_normal = EnvArt.tex("crafting", "door")
	door.ignore_texture_size = true
	door.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	door.custom_minimum_size = Vector2(STRIP_H * DOOR_ASPECT, STRIP_H)
	door.size_flags_vertical = SIZE_SHRINK_END
	door.tooltip_text = "Leave"
	door.pressed.connect(_leave)
	door.mouse_entered.connect(func() -> void: door.modulate = Color(1.18, 1.18, 1.18))
	door.mouse_exited.connect(func() -> void: door.modulate = Color.WHITE)
	strip.add_child(door)
	_door = door

	# Shelf cell: fills the row's full height (matching the door) so its fixed SHELF_TOP_MARGIN
	# lands the shelf centred on the WALLPAPER's span rather than the door's taller one.
	var shelf_cell := MarginContainer.new()
	shelf_cell.size_flags_horizontal = SIZE_EXPAND_FILL
	shelf_cell.add_theme_constant_override("margin_top", int(SHELF_TOP_MARGIN))
	shelf_cell.add_theme_constant_override("margin_right", 20)
	strip.add_child(shelf_cell)

	var shelf := PanelContainer.new()
	shelf.size_flags_horizontal = SIZE_EXPAND_FILL
	shelf.size_flags_vertical = SIZE_SHRINK_BEGIN
	shelf.custom_minimum_size.y = SHELF_H
	var shelf_style := StyleBoxTexture.new()
	shelf_style.texture = EnvArt.tex("crafting", "charm_shelf")
	shelf_style.set_content_margin_all(12)
	shelf.add_theme_stylebox_override("panel", shelf_style)
	shelf_cell.add_child(shelf)
	_shelf = shelf

	var shelf_scroll := ScrollContainer.new()
	shelf_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	shelf_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	shelf.add_child(shelf_scroll)
	_charm_col = HBoxContainer.new()
	_charm_col.size_flags_vertical = SIZE_EXPAND_FILL
	_charm_col.add_theme_constant_override("separation", 12)
	shelf_scroll.add_child(_charm_col)

	# The fitted spread is usually a touch narrower than the viewport (whole columns only) — the
	# wrap centres it so the leftover reads as even table margin, not a dead strip on one side
	# (ScrollContainer itself pins its child top-left regardless of shrink flags).
	var grid_wrap := VBoxContainer.new()
	grid_wrap.size_flags_horizontal = SIZE_EXPAND_FILL
	grid_wrap.size_flags_vertical = SIZE_EXPAND_FILL
	grid_wrap.alignment = BoxContainer.ALIGNMENT_CENTER   # small decks sit mid-table, not top-stuck
	scroll.add_child(grid_wrap)
	_deck_grid = GridContainer.new()
	_deck_grid.columns = 4
	_deck_grid.add_theme_constant_override("h_separation", int(GRID_SEP))
	_deck_grid.add_theme_constant_override("v_separation", int(GRID_SEP))
	_deck_grid.size_flags_horizontal = SIZE_SHRINK_CENTER
	grid_wrap.add_child(_deck_grid)

	# Right: the alchemy station — ingredient slots (A + B), the result with its full description,
	# the Mineral balance, a status line and the Combine button.
	var station := PanelContainer.new()
	station.size_flags_horizontal = SIZE_EXPAND_FILL
	station.size_flags_vertical   = SIZE_EXPAND_FILL
	station.size_flags_stretch_ratio = 1.0
	var station_style := StyleBoxTexture.new()
	station_style.texture = EnvArt.tex("crafting", "station")
	station_style.set_content_margin_all(24)
	station.add_theme_stylebox_override("panel", station_style)
	body.add_child(station)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 12)
	station.add_child(right)

	# Mineral balance — the currency merges spend; it lives at the station since there's no header.
	var chip := PanelContainer.new()
	var chip_style := StyleBoxFlat.new()
	chip_style.bg_color = Color("2a9178")
	chip_style.set_corner_radius_all(12)
	chip_style.set_content_margin_all(14)
	chip.add_theme_stylebox_override("panel", chip_style)
	right.add_child(chip)
	var chip_row := HBoxContainer.new()
	chip_row.alignment = BoxContainer.ALIGNMENT_CENTER
	chip_row.add_theme_constant_override("separation", 14)
	chip.add_child(chip_row)
	var chip_tag := Label.new()
	chip_tag.text = "Mineral"
	chip_tag.add_theme_font_size_override("font_size", 32)
	chip_tag.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	chip_row.add_child(chip_tag)
	_mineral_value = Label.new()
	_mineral_value.add_theme_font_size_override("font_size", 32)
	_mineral_value.add_theme_color_override("font_color", Color.WHITE)
	chip_row.add_child(_mineral_value)
	GameSignals.mineral_changed.connect(func(v: int) -> void: _mineral_value.text = str(v))
	if GameData.current_run != null:
		_mineral_value.text = str(GameData.current_run.magic_mineral)

	# Slot cluster: the two ingredients stacked VERTICALLY on the left (A over "+" over B) with the
	# RESULT as the big card beside them, spanning the pair's height — the whole merge reads
	# left-to-right as one equation: (A + B) → result. Sizes come from _fit_station — the initial
	# minimums here stay conservatively SMALL: an oversized first-frame minimum inflates the whole
	# body before the fit pass runs, which overflowed the screen on small windows.
	_slot_size = Vector2(90, 118)
	var cluster := HBoxContainer.new()
	cluster.alignment = BoxContainer.ALIGNMENT_CENTER
	cluster.add_theme_constant_override("separation", 8)
	right.add_child(cluster)

	var ing_col := VBoxContainer.new()
	ing_col.alignment = BoxContainer.ALIGNMENT_CENTER
	ing_col.add_theme_constant_override("separation", 0)
	cluster.add_child(ing_col)
	var sa := _make_card_slot(_slot_size, "")
	_slot_a = sa["holder"]
	ing_col.add_child(sa["slot"])
	var plus := _strip_glyph("+", 32)
	plus.size_flags_horizontal = SIZE_SHRINK_CENTER
	ing_col.add_child(plus)
	var sb := _make_card_slot(_slot_size, "")
	_slot_b = sb["holder"]
	ing_col.add_child(sb["slot"])

	cluster.add_child(_strip_glyph("→", 48))

	var sr := _make_card_slot(Vector2(140, 183), "")
	_result_slot = sr["holder"]
	cluster.add_child(sr["slot"])
	right.resized.connect(_fit_station.bind(right))

	# Text band under the cluster: the result read (name + cost + rules, font SHRINKS with length)
	# on the left, the result's ability tokens on the right. A visible box marks it as the read
	# area — its own surface with an inner margin, content pinned top-left. FIXED MINIMUM height —
	# length changes re-size the font to fit INSIDE it (never scroll); nothing around it ever moves.
	# The band's wrapper takes the column's leftover height (the cluster above and the Combine
	# button below both pack to their own content), and the box FILLS it — margins on all four
	# sides match (12px), so it reads as a small even gap against the slots above and the button
	# below, the same way the side margins read against the column's edges.
	var band_margin := MarginContainer.new()
	band_margin.size_flags_vertical = SIZE_EXPAND_FILL
	for side: String in ["left", "right", "top", "bottom"]:
		band_margin.add_theme_constant_override("margin_" + side, 12)
	right.add_child(band_margin)
	var band_panel := PanelContainer.new()
	band_panel.size_flags_vertical = SIZE_EXPAND_FILL
	var band_style := StyleBoxFlat.new()
	band_style.bg_color = Color(0, 0, 0, 0.28)
	band_style.set_corner_radius_all(10)
	band_style.set_content_margin_all(14)
	band_panel.add_theme_stylebox_override("panel", band_style)
	band_margin.add_child(band_panel)
	var band := HBoxContainer.new()
	band.custom_minimum_size.y = 170
	band.add_theme_constant_override("separation", 10)
	band_panel.add_child(band)
	# Plain Control, not a ScrollContainer: the read never scrolls — _shrink_result_text always
	# shrinks the font until it fits instead (clip_contents is just a safety net against a stray
	# overflow, not an intended path).
	var text_box := Control.new()
	text_box.clip_contents = true
	text_box.size_flags_horizontal = SIZE_EXPAND_FILL
	band.add_child(text_box)
	_result_text_box = text_box
	var band_col := VBoxContainer.new()
	band_col.size_flags_horizontal = SIZE_EXPAND_FILL
	band_col.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	text_box.add_child(band_col)
	# The status line (invalid pair / cost verdict) lives INSIDE the fixed text box, above the
	# result read — appearing/disappearing must never move the layout around it.
	_preview_status = Label.new()
	_preview_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_status.add_theme_font_size_override("font_size", 24)
	# Explicit colour + outline (not modulate over the theme's label colour, which muddies it) so
	# the verdict pops from the dark box; _refresh_forge overrides the colour per verdict.
	_preview_status.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_preview_status.add_theme_constant_override("outline_size", 4)
	_preview_status.size_flags_horizontal = SIZE_EXPAND_FILL
	band_col.add_child(_preview_status)
	_result_info = VBoxContainer.new()
	_result_info.size_flags_horizontal = SIZE_EXPAND_FILL
	band_col.add_child(_result_info)
	_ability_strip = HBoxContainer.new()
	_ability_strip.alignment = BoxContainer.ALIGNMENT_CENTER
	_ability_strip.add_theme_constant_override("separation", 6)
	band.add_child(_ability_strip)

	_combine_btn = ScreenUI.action_button("Combine", _on_combine_pressed,
		Vector2(0, 100), 32, ScreenUI.CHROME_CONFIRM)
	_combine_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	right.add_child(_combine_btn)

	# Drag overlay: floats above everything, never eats input.
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_overlay)


# ── Deck display ────────────────────────────────────────────────────────────────

# Fit-all: pick the column count that shows the WHOLE deck at the largest card size (native
# aspect) — deck sizes are bounded, so scrolling here is pointless (user directive) and stays a
# floor-degradation path only. Ties prefer fewer remainder holes, then the wider spread.
func _fit_cards() -> void:
	if _scroll == null or _deck_grid == null or _entries.is_empty():
		return
	var avail := _scroll.size
	if avail.x <= 0.0 or avail.y <= 0.0:
		return
	var sep := GRID_SEP
	var n := _entries.size()
	var floor_w := 150.0
	var best_w := 0.0
	var best_cols := 1
	for cols in range(1, n + 1):
		var rows := int(ceil(float(n) / float(cols)))
		var w := (avail.x - float(cols - 1) * sep) / float(cols)
		var h_cap := (avail.y - float(rows - 1) * sep) / float(rows)
		w = minf(w, h_cap / CARD_ASPECT)
		if w > best_w + 0.5:
			best_w = w
			best_cols = cols
		elif absf(w - best_w) <= 0.5:
			# Tie on card size → prefer the layout with FEWER remainder holes (a ragged last row
			# is dead cells; excess width instead flows to the rail). Same holes → wider spread.
			# Always adopt THIS column count's width — keeping the old one overflowed the row.
			var rem_new := (cols - (n % cols)) % cols
			var rem_best := (best_cols - (n % best_cols)) % best_cols
			if rem_new < rem_best or (rem_new == rem_best and cols > best_cols):
				best_w = w
				best_cols = cols
	if best_w < floor_w:
		# Absurdly large deck: clamp to the touch floor and let the grid scroll (bar gets a lane).
		best_w = floor_w
		var bar_w := _scroll.get_v_scroll_bar().get_combined_minimum_size().x
		best_cols = maxi(int((avail.x - bar_w + sep) / (floor_w + sep)), 1)
	# Elastic gutters: whole cards at a fixed aspect can't fill both dimensions exactly, so the
	# integer-grid remainder is spent on the separations instead — each axis's slack is split into
	# one share per column/row (SHRINK_CENTER turns the odd share into equal half-gap edges), so
	# the spread always reads as touching all four table edges. Slack in a scrolling grid's long
	# axis is 0 by construction (maxf guards the sign).
	var rows_n := int(ceil(float(n) / float(best_cols)))
	var grid_w := float(best_cols) * best_w + float(best_cols - 1) * sep
	var grid_h := float(rows_n) * best_w * CARD_ASPECT + float(rows_n - 1) * sep
	var h_extra := maxf(avail.x - grid_w, 0.0) / float(best_cols)
	var v_extra := maxf(avail.y - grid_h, 0.0) / float(rows_n)
	_deck_grid.add_theme_constant_override("h_separation", int(sep + h_extra))
	_deck_grid.add_theme_constant_override("v_separation", int(sep + v_extra))

	var new_size := Vector2(best_w, best_w * CARD_ASPECT)
	if new_size.distance_to(_card_size) < 1.0 and _deck_grid.columns == best_cols:
		return
	_card_size = new_size
	_deck_grid.columns = best_cols
	for e: Dictionary in _entries:
		(e.item as Control).custom_minimum_size = _card_size
		(e.ui as Control).custom_minimum_size = _card_size


# Sizes the slot cluster from the station column's measured rect. The column splits between the
# stacked ingredient pair and the result at a fixed width ratio (result dominates), then each side
# is capped by the height left after the fixed rows (chip + text band + status/button ≈ 340).
# Never driven by the preview text, so a changing description can't move or resize anything.
func _fit_station(right: Control) -> void:
	if _result_slot == null:
		return
	var avail := right.size
	if avail.x <= 0.0 or avail.y <= 0.0:
		return
	# Height budget from the VIEWPORT, not right.size: the sizes computed here become the column's
	# own minimums, so measuring ourselves feeds back (an inflated first layout re-justifies itself
	# and the screen sticks overflowed). The viewport can't be inflated by us: window minus the
	# outer pad + station margins (~76) is the honest ceiling on the column's height.
	var avail_y := minf(avail.y, get_viewport_rect().size.y - 80.0)
	var cluster_h := maxf(avail_y - 420.0, 180.0)
	var lanes := 76.0    # the "→" lane + the cluster's separations
	var glyph_h := 46.0  # the "+" lane between the stacked ingredients (glyph line height)
	var ratio := 0.6     # ingredient card width as a share of the result's
	var res_w := (avail.x - lanes) / (1.0 + ratio)
	var ing_w := res_w * ratio
	res_w = minf(res_w, cluster_h / CARD_ASPECT)
	ing_w = minf(ing_w, (cluster_h - glyph_h) * 0.5 / CARD_ASPECT)
	_slot_size = Vector2(ing_w, ing_w * CARD_ASPECT)
	(_slot_a.get_parent() as Control).custom_minimum_size = _slot_size
	(_slot_b.get_parent() as Control).custom_minimum_size = _slot_size
	(_result_slot.get_parent() as Control).custom_minimum_size = Vector2(res_w, res_w * CARD_ASPECT)


func _rebuild_deck() -> void:
	_cancel_drag()
	for child in _deck_grid.get_children():
		child.queue_free()
	_entries.clear()
	_sel_a = -1
	_sel_b = -1
	_sel_charm = ""

	var deck: Array = GameData.current_run.deck.duplicate()
	for i in deck.size():
		var dc: DeckCard = deck[i]
		var data := CardData.get_card(dc.id)
		if data == null:
			continue
		var ui := CardUI.create(dc.make_instance())
		ui.draggable = false   # the Forge drives its own drag; CardUI's combat drag stays off
		ui.custom_minimum_size = _card_size

		var combinable := data.elements.size() > 0 or data.chess_pieces.size() > 0
		var entry_idx := _entries.size()

		# Every card is wrapped so it can be a drop TARGET (rect hit-test); only combinable cards
		# are draggable SOURCES. Non-combinable cards are dimmed but can still receive a charm.
		var item := ForgeDragItem.new()
		item.custom_minimum_size = _card_size
		item.setup(ui, {"kind": "card", "idx": entry_idx})
		# Hover detail comes from the CardUI's OWN standard tooltip (ForgeDragItem leaves the card on
		# MOUSE_FILTER_PASS) — the same path the rest of the game uses; nothing bespoke here.
		if combinable:
			item.grab.connect(_on_press)
		else:
			ui.modulate = Color(1, 1, 1, 0.35)

		_entries.append({ "card": dc, "deck_idx": i, "data": data, "ui": ui, "item": item })
		_deck_grid.add_child(item)

	_fit_cards()   # deck count changed — resize the table's cards to fit the new spread
	_refresh_forge()


# ── Charm inventory ──────────────────────────────────────────────────────────────

func _rebuild_charms() -> void:
	for child in _charm_col.get_children():
		child.queue_free()

	var counts: Dictionary = {}
	for charm_id: String in GameData.current_run.charms:
		counts[charm_id] = int(counts.get(charm_id, 0)) + 1

	if counts.is_empty():
		var empty := Label.new()
		empty.text = "(no charms)"
		empty.size_flags_horizontal = SIZE_EXPAND_FILL   # centre in the row, not left-stuck
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 18)
		empty.add_theme_color_override("font_color", Color(0.9, 0.85, 0.75, 0.6))
		_charm_col.add_child(empty)
		return

	for charm_id: String in counts:
		_charm_col.add_child(_make_charm_item(charm_id, counts[charm_id]))


# A draggable charm chip (with ×N count). Dragging it onto a card enchants that card.
func _make_charm_item(charm_id: String, count: int) -> ForgeDragItem:
	var size := CHARM_SIZE
	var item := ForgeDragItem.new()
	item.custom_minimum_size = size
	# Fixed square badge centred in the shelf row's height.
	item.size_flags_vertical = SIZE_SHRINK_CENTER
	item.setup(_make_charm_chip(charm_id, count, size), {"kind": "charm", "id": charm_id})
	var charm := CharmData.get_charm(charm_id)
	if charm != null:
		item.tooltip_text = "%s — %s" % [charm.display_name, charm.description]
	item.grab.connect(_on_press)
	return item


func _make_charm_chip(charm_id: String, count: int, size: Vector2) -> Control:
	var charm := CharmData.get_charm(charm_id)
	var chip: Panel = TextIcons.TipPanel.new()   # tooltip renders keyword icons
	chip.custom_minimum_size = size
	var style := StyleBoxFlat.new()
	style.bg_color = (charm.color.lightened(0.1) if charm != null else Color(0.4, 0.4, 0.5))
	style.set_corner_radius_all(int(size.x * 0.5))
	style.set_border_width_all(2)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	chip.add_theme_stylebox_override("panel", style)
	if charm != null:
		chip.tooltip_text = "%s — %s" % [charm.display_name, charm.description]

	var lbl := Label.new()
	lbl.text = (charm.letter if charm != null else "✦")
	if count > 1:
		lbl.text += " ×%d" % count
	lbl.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", maxi(int(size.x * 0.3), 14))
	lbl.add_theme_color_override("font_color", Color(0.98, 0.98, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.mouse_filter = MOUSE_FILTER_IGNORE
	chip.add_child(lbl)
	return chip


# ── Drag session ──────────────────────────────────────────────────────────────

func _begin_drag(payload: Dictionary) -> void:
	if not _drag.is_empty():
		return
	_drag = payload
	_hover_idx = -1
	_result_deck_card = null

	var visual: Control = _make_follower_visual(payload)
	var half := visual.custom_minimum_size * 0.5
	_follower = Control.new()
	_follower.mouse_filter = MOUSE_FILTER_IGNORE
	# The dragged item is enlarged either way. Cards always centre on the pointer. A charm centres on
	# the pointer on desktop (a mouse cursor occludes nothing), but on a TOUCH device it lifts above
	# the finger — a chip under a fingertip is invisible while dragging. When lifted, the hit-test and
	# the vortex follow the chip's centre via _follower_center (see _update_drag).
	if payload.kind == "charm" and DisplayServer.is_touchscreen_available():
		var lift := 48.0
		visual.position = Vector2(-half.x, -visual.custom_minimum_size.y - lift)
	else:
		visual.position = -half   # centre the visual on the pointer
	visual.pivot_offset = half   # so wobble rotates around its centre
	_follower.add_child(visual)
	_overlay.add_child(_follower)
	_follower_visual = visual
	_follower_base_pos = visual.position
	_follower_center = visual.position + half   # visual centre vs pointer (0 for cards; lifted for charms)
	_wob_t = 0.0
	_wob = 0.0

	var r := _aura_radii(payload)
	_aura = _make_aura(_source_color(payload), r.x, r.y)
	_aura.position = _follower_center   # keep the halo on the (possibly lifted) visual, not the pointer
	_follower.add_child(_aura)
	Sfx.mixing_start()   # the aura's audio half — loops for exactly as long as the particles swirl

	# Leave the dragged source IN PLACE as a dimmed "ghost": its grid slot stays occupied, so the
	# grid never reflows mid-drag. Cards staying put avoids accidental drops on one that slid under
	# the pointer. The follower in the overlay is what the player actually moves.
	if payload.kind == "card":
		_entries[payload.idx].item.modulate.a = 0.28

	_refresh_forge()   # show the dragged card in slot A right away
	_update_drag(get_global_mouse_position())


func _make_follower_visual(payload: Dictionary) -> Control:
	if payload.kind == "card":
		var inst: CardInstance = _entries[payload.idx].card.make_instance()
		var ui := CardUI.create(inst)
		ui.custom_minimum_size = _card_size
		ui.size = _card_size
		ui.modulate.a = 0.85
		return ui
	var size := _charm_follower_size()
	var chip := _make_charm_chip(payload.id, 1, size)
	chip.custom_minimum_size = size
	chip.size = size
	return chip


# The dragged charm chip's size — normal (same as before). Touch visibility is handled by LIFTING
# the chip above the finger (see _begin_drag), not by enlarging it; desktop needs neither.
func _charm_follower_size() -> Vector2:
	return Vector2(64, 64)


# Drives the dragged card's wobble: it eases in while a link is active, out when it breaks.
func _process(delta: float) -> void:
	if _follower_visual == null:
		return
	_auto_scroll(delta)
	var cfg := ForgeFX.CARD
	var connected := 1.0 if _link != null else 0.0
	_wob = lerpf(_wob, connected, clampf(delta * float(cfg["wobble_ease"]), 0.0, 1.0))
	if _wob < 0.001:
		_follower_visual.rotation = 0.0
		_follower_visual.position = _follower_base_pos
		if _target_item != null:
			_target_item.rotation = 0.0
		return
	_wob_t += delta
	var freq := float(cfg["wobble_freq"])
	var rot := _wob * float(cfg["wobble_rot"])
	_follower_visual.rotation = rot * sin(_wob_t * freq)
	# The dragged card lunges toward its target so the pair reads as PULLING together — the same
	# motion the merge FX gives the static pair (ForgeFX.CARD.pull_*). Rotation only for the target
	# (it lives in the scrolling grid, which manages its position), a half-cycle out of phase.
	var pull_off := Vector2.ZERO
	if _target_item != null:
		var to_target := _target_item.get_global_rect().get_center() - (_follower.global_position + _follower_center)
		if to_target.length() > 0.01:
			var pull := _wob * (_follower_visual.size.x * float(cfg["pull_frac"])) \
				* (0.5 - 0.5 * cos(_wob_t * freq * float(cfg["pull_freq_mult"])))
			pull_off = to_target.normalized() * pull
		_target_item.rotation = rot * sin(_wob_t * freq + PI * 0.5)
	_follower_visual.position = _follower_base_pos + pull_off


func _input(event: InputEvent) -> void:
	# While the confirm overlay is up, swallow input here (Esc cancels it) so a stray tap/drag
	# can't reshuffle the deck behind it and Nav doesn't also fire.
	if _combine_modal != null:
		if event.is_action_pressed("ui_cancel"):
			if not _fusing:            # mid-fusion Esc is swallowed but must NOT abort the sequence
				_close_combine_modal()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		if not _drag.is_empty():
			_update_drag(get_global_mouse_position())
		elif not _pending.is_empty() and get_global_mouse_position().distance_to(_press_pos) > DRAG_THRESHOLD:
			# Moved past the threshold — promote the pending press into a real drag.
			var p := _pending
			_pending = {}
			_begin_drag(p)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			# NOTE: do NOT set_input_as_handled() here. _input runs before Godot's GUI layer; eating
			# the button-up means the GUI never sees it, so Godot keeps thinking the button is held
			# on the last-pressed card and FREEZES gui.mouse_over — which froze hover tooltips on the
			# last-clicked card. Letting the release reach the GUI keeps hover tracking correct.
			if not _drag.is_empty():
				_resolve_drag()
			elif not _pending.is_empty():
				# Released without dragging — it's a tap (select).
				var p := _pending
				_pending = {}
				_on_tap(p)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if not _drag.is_empty():
				_cancel_drag()   # right-click aborts the drag without merging
				get_viewport().set_input_as_handled()
			elif not _pending.is_empty():
				_pending = {}


func _update_drag(global_pos: Vector2) -> void:
	if _follower == null:
		return
	_follower.global_position = global_pos
	# Hit-test from the follower VISUAL centre (lifted for charms), not the raw pointer — otherwise a
	# lifted charm chip visibly overlapping a card wouldn't register, since the pointer sits below it.
	var hit := global_pos + _follower_center
	_set_hover(_target_under(hit))
	if _link != null and _hover_idx >= 0:
		# Connect the two cards' orbit rings, in overlay-local space (source = the visual centre).
		var inv := _overlay.get_global_transform().affine_inverse()
		var tgt: Control = _entries[_hover_idx].item
		var rr := _card_aura_radii()
		_link.set_endpoints(inv * hit, inv * tgt.get_global_rect().get_center(), rr.x, rr.y)


# While dragging, ease the deck scroll up/down when the pointer nears the top/bottom edge,
# so cards out of view can be reached without letting go. Hover/link are refreshed as it shifts.
func _auto_scroll(delta: float) -> void:
	if _scroll == null:
		return
	var rect := _scroll.get_global_rect()
	var zone := 110.0   # edge band that triggers scrolling
	var speed := 1100.0                        # px/sec at the very edge
	var y := get_global_mouse_position().y
	var dv := 0.0
	if y < rect.position.y + zone:
		dv = -(1.0 - clampf((y - rect.position.y) / zone, 0.0, 1.0))
	elif y > rect.end.y - zone:
		dv = 1.0 - clampf((rect.end.y - y) / zone, 0.0, 1.0)
	if dv == 0.0:
		return
	var before := _scroll.scroll_vertical
	_scroll.scroll_vertical = before + int(dv * speed * delta)
	if _scroll.scroll_vertical != before:
		_update_drag(get_global_mouse_position())   # cards moved under the cursor — re-evaluate


# The index of the deck card under `global_pos`, excluding the dragged source itself; -1 if none.
func _target_under(global_pos: Vector2) -> int:
	for i in _entries.size():
		if _drag.get("kind") == "card" and int(_drag.get("idx", -1)) == i:
			continue
		var item: Control = _entries[i].item
		if item != null and item.get_global_rect().has_point(global_pos):
			return i
	return -1


func _set_hover(target_idx: int) -> void:
	if target_idx == _hover_idx:
		return
	_clear_hover_visuals()
	_hover_idx = target_idx
	if target_idx < 0:
		_refresh_forge()
		return

	var verdict := _evaluate_target(_drag, target_idx)
	_result_deck_card = verdict.get("result_dc", null)
	_refresh_forge()   # slot A = dragged, slot B = hovered, result previewed

	if bool(verdict.get("ok", false)):
		var col: Color = verdict.get("color", OK_COLOR)
		# Both halos whirl faster/brighter and a swirling vortex pulls motes between the two cards.
		var connect_intensity := float(ForgeFX.AURA["connect_intensity"])
		_aura.set_intensity(connect_intensity)
		Sfx.mixing_react(true)   # the rev-up is the intensified halos' audio half
		var inv := _overlay.get_global_transform().affine_inverse()
		var center := inv * (_entries[target_idx].item as Control).get_global_rect().get_center()
		var rr := _card_aura_radii()
		_target_aura = _make_aura(col, rr.x, rr.y)
		_target_aura.position = center
		_target_aura.set_intensity(connect_intensity)
		_overlay.add_child(_target_aura)
		_link = ForgeLink.new()
		_link.setup(col)
		_link.set_endpoints(inv * (_follower.global_position + _follower_center), center, rr.x, rr.y)
		_overlay.add_child(_link)
		# Mark the target card so _process can wobble it too (rotating around its centre).
		_target_item = _entries[target_idx].item
		_target_item.pivot_offset = _target_item.size * 0.5


func _clear_hover_visuals() -> void:
	Sfx.mixing_react(false)
	if _aura != null:
		_aura.set_intensity(1.0)
	if _target_aura != null:
		_target_aura.queue_free()
		_target_aura = null
	if _link != null:
		_link.queue_free()
		_link = null
	if _target_item != null:
		_target_item.rotation = 0.0
		_target_item = null


func _resolve_drag() -> void:
	var payload := _drag
	var hover := _hover_idx
	var verdict: Dictionary = _evaluate_target(payload, hover) if hover >= 0 else {}
	var ok: bool = bool(verdict.get("ok", false))
	# Capture what's needed before teardown clears state.
	var src_idx: int = int(payload.get("idx", -1))
	var charm_id: String = str(payload.get("id", ""))
	_cancel_drag()
	if not ok:
		return
	if payload.get("kind") == "card":
		# Dropping a card onto another just APPOINTS the pair into the station's ingredient slots —
		# the same result as tapping them one at a time. Combining itself (destructive: both
		# originals consumed) still needs an explicit press of the station's Combine button.
		_sel_a = src_idx
		_sel_b = hover
		_sel_charm = ""
		_update_selection_highlights()
		_refresh_forge()
	else:
		# Charms enchant the card they're dropped on directly — non-destructive, no confirmation
		# needed (it just spends the charm).
		_do_enchant(charm_id, hover)


func _close_combine_modal() -> void:
	if _combine_modal != null:
		Sfx.mixing_react(false)
		Sfx.mixing_stop()   # the modal's swirl drone (FX itself is freed with the dim)
		_combine_modal.queue_free()
		_combine_modal = null
	# Children (fusion, toast) are freed with the dim — just drop our references.
	_fusing = false
	_fuse_anim = null
	# The panel path hides its static slot cards during the fusion — restore them (no-op otherwise).
	if _slot_a != null:
		_slot_a.visible = true
	if _slot_b != null:
		_slot_b.visible = true
	if _result_slot != null:
		_result_slot.visible = true


# Panel "Combine" pressed — the panel already shows A+B→result, so this is the single destructive
# commit point (no confirm modal). Build the input-blocking backdrop (reusing _combine_modal so
# close/Esc/toast all work), hide the static slot cards, and play the fusion right on where they
# sit. Silent until the flash (the side panel has no reaction drone — only the combined SFX at impact).
func _start_panel_fusion(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	if _fusing or _combine_modal != null or result_dc == null:
		return

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if _fusing:
			return
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close_combine_modal())
	add_child(dim)
	_combine_modal = dim
	_fusing = true

	# The fusion carries its own swirl; drop the preview swirl and hide the static slot cards so the
	# flying clones (which start right on them) don't double up.
	if _panel_fx != null:
		_panel_fx.queue_free()
		_panel_fx = null
	_panel_fx_key = ""
	_slot_a.visible = false
	_slot_b.visible = false
	_result_slot.visible = false

	_begin_fusion(src_idx, tgt_idx, result_dc, _slot_a, _slot_b)


# Shared fusion launcher: flies clones of the two source cards (read from `holder_a`/`holder_b`) into
# their midpoint over the active _combine_modal, commits the merge at the flash, and reveals the
# result toast. Both the modal (drag-drop) path and the panel path funnel through here.
func _begin_fusion(src_idx: int, tgt_idx: int, result_dc: DeckCard, holder_a: Control, holder_b: Control) -> void:
	var a_center := holder_a.get_global_rect().get_center()
	var b_center := holder_b.get_global_rect().get_center()
	var card_size := holder_a.size
	# The pair collides at the midpoint between them — each flies straight at the other. (The result
	# toast that follows is screen-centred, so its fade-in absorbs the small hop from here.)
	var center := (a_center + b_center) * 0.5

	var a_inst := (_entries[src_idx].card as DeckCard).make_instance()
	var b_inst := (_entries[tgt_idx].card as DeckCard).make_instance()
	var result_inst := result_dc.make_instance()
	var color_a := _color_for_card(_entries[src_idx].data)
	var color_b := _color_for_card(_entries[tgt_idx].data)

	var anim := ForgeFuseAnim.new()
	anim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# At the flash: stop any reaction drone, then commit the merge (mutate deck + rebuild + combined
	# SFX) — all hidden behind the white.
	anim.flashed.connect(_on_fuse_flash.bind(src_idx, tgt_idx, result_dc))
	anim.finished.connect(_on_fuse_finished.bind(result_inst))
	_combine_modal.add_child(anim)
	_fuse_anim = anim

	# The merge flash announces the newborn card's element: the combine element-variant bursts
	# at the collision point exactly when the white flash commits the merge. No variant live
	# (or placeholders muted) = the anim's own flash carries the moment, as before.
	var combine_vid := Vfx.resolve("combine", result_inst.data.elements)
	if not combine_vid.is_empty():
		var marker := Control.new()
		marker.mouse_filter = MOUSE_FILTER_IGNORE
		marker.size = Vector2(120, 120)
		_combine_modal.add_child(marker)   # dies with the modal
		marker.global_position = center - marker.size * 0.5
		anim.flashed.connect(func() -> void: Vfx.play(combine_vid, marker))

	anim.play(a_inst, b_inst, result_inst, a_center, b_center, center, card_size, color_a, color_b, OK_COLOR)


func _on_fuse_flash(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	Sfx.mixing_react(false)
	Sfx.mixing_stop()   # the reaction drone ends as the pair flashes into one
	_do_combine(src_idx, tgt_idx, result_dc)


func _on_fuse_finished(result_inst: CardInstance) -> void:
	_show_result_toast(result_inst)


# The dismissible "Forged!" toast: the new card centred over the dim with its name + description.
# Clicking the dim (outside the card) closes the whole modal; the card panel swallows its own clicks,
# so it's a true "click out to dismiss". Merge is already committed by this point.
func _show_result_toast(result_inst: CardInstance) -> void:
	if _combine_modal == null:
		return
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_combine_modal.add_child(center)

	var panel := PanelContainer.new()
	panel.mouse_filter = MOUSE_FILTER_STOP   # swallow clicks — only a click OUTSIDE (on the dim) closes
	var style := StyleBoxFlat.new()
	style.bg_color = Color(ScreenUI.SURFACE_DEEP, 0.98)
	style.set_border_width_all(2)
	style.border_color = ScreenUI.SURFACE_DEEP_BORDER
	style.set_corner_radius_all(10)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	Vfx.play("ui_toast_glint", panel)   # the "Forged!" notice announces itself (carries its sound)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	var title := Label.new()
	title.text = "Forged!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", OK_COLOR)
	col.add_child(title)

	var cs := Vector2(230, 301)
	var holder := Control.new()
	holder.custom_minimum_size = cs
	holder.size_flags_horizontal = SIZE_SHRINK_CENTER
	var card := CardUI.create(result_inst)
	card.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	card.mouse_filter = MOUSE_FILTER_IGNORE
	holder.add_child(card)
	col.add_child(holder)

	var name_lbl := Label.new()
	name_lbl.text = result_inst.data.display_name
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 18)
	col.add_child(name_lbl)

	var desc := result_inst.data.description
	if not desc.is_empty():
		var desc_lbl := TextIcons.rich_label(desc, 14, Color("3a2f22"), true)
		desc_lbl.custom_minimum_size.x = 280.0
		col.add_child(desc_lbl)

	var hint := Label.new()
	hint.text = "Tap anywhere to continue"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color("5a4a38"))
	col.add_child(hint)

	# The toast now covers the reveal — drop the animation and re-arm click-to-dismiss.
	if _fuse_anim != null:
		_fuse_anim.queue_free()
		_fuse_anim = null
	_fusing = false
	center.modulate.a = 0.0
	create_tween().tween_property(center, "modulate:a", 1.0, 0.18)


# Tears down the in-flight drag visuals and restores the hidden source. Safe to call anytime.
# Every drag ends through here (drop resolves, right-click abort, screen exit), so this is the
# single stop point for the mixing loop started in _begin_drag.
func _cancel_drag() -> void:
	Sfx.mixing_stop()
	_clear_hover_visuals()
	if _follower != null:
		_follower.queue_free()
		_follower = null
	_follower_visual = null
	_aura = null
	if not _drag.is_empty() and _drag.get("kind") == "card":
		var idx := int(_drag.get("idx", -1))
		if idx >= 0 and idx < _entries.size() and _entries[idx].item != null:
			_entries[idx].item.modulate.a = 1.0   # un-ghost the source back to normal
	_drag = {}
	_hover_idx = -1
	_result_deck_card = null
	_refresh_forge()   # revert the slots to the click-selected pair (if any)


# ── Validity + preview ──────────────────────────────────────────────────────────

# Evaluates dropping `payload` on the card at `target_idx`. Returns:
#   { ok, status, color, preview: CardInstance|null, result_dc: DeckCard|null }
func _evaluate_target(payload: Dictionary, target_idx: int) -> Dictionary:
	var tgt: Dictionary = _entries[target_idx]
	if payload.kind == "card":
		var a: CardData = _entries[int(payload.idx)].data
		var b: CardData = tgt.data
		if not CardData.can_combine(a, b):
			return {"ok": false, "status": "Exceeds the combination limit (2 elements + 2 chess pieces)", "color": BAD_COLOR}
		var result := CardData.combine(a, b)
		var rdc := DeckCard.make(result.id)
		for charm_id: String in _merged_parent_charms([_entries[int(payload.idx)].card, tgt.card], result):
			rdc.add_charm(charm_id)
		# Merging costs Magic Mineral (see ForgeCosts). An unaffordable pair still previews its
		# result (ok stays true) but can't be forged — every action path gates on "affordable".
		var cost := ForgeCosts.merge_cost(a, b)
		var have: int = GameData.current_run.magic_mineral if GameData.current_run != null else 0
		# The result's name/description render at the station (see _refresh_forge) — the status
		# line only carries the cost verdict.
		if have < cost:
			return {"ok": true, "affordable": false, "cost": cost,
				"status": "Needs %d Mineral — you have %d" % [cost, have],
				"color": BAD_COLOR, "preview": rdc.make_instance(), "result_dc": rdc}
		# Affordable: the cost renders on the Combine button itself — no status text needed.
		return {"ok": true, "affordable": true, "cost": cost, "status": "",
			"color": OK_COLOR, "preview": rdc.make_instance(), "result_dc": rdc}
	else:
		var charm := CharmData.get_charm(str(payload.id))
		var data: CardData = tgt.data
		if charm == null:
			return {"ok": false}
		if not charm.can_attach_to(data):
			return {"ok": false, "status": "%s can't bear the %s charm." % [data.display_name, charm.display_name], "color": BAD_COLOR}
		if str(payload.id) in (tgt.card as DeckCard).charms:
			return {"ok": false, "status": "%s already bears %s." % [data.display_name, charm.display_name], "color": WARN_COLOR}
		var preview_dc := (tgt.card as DeckCard).clone()
		preview_dc.add_charm(str(payload.id))
		return {"ok": true, "status": "Enchant %s with %s" % [data.display_name, charm.display_name],
			"color": OK_COLOR, "preview": preview_dc.make_instance()}


# Union of both parents' charms still valid on the combined result.
func _merged_parent_charms(parents: Array, result_card: CardData) -> Array:
	var out: Array = []
	for dc: DeckCard in parents:
		for charm_id: String in dc.charms:
			var charm := CharmData.get_charm(charm_id)
			if charm != null and charm.can_attach_to(result_card) and charm_id not in out:
				out.append(charm_id)
	return out


# A dim "+" / "→" glyph for the station's ingredient strip, centred on the tokens' height.
func _strip_glyph(glyph: String, font_size: int) -> Label:
	var lbl := Label.new()
	lbl.text = glyph
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.modulate = IDLE_COLOR
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


# A card-shaped slot (framed PanelContainer) with an inner holder + a placeholder label shown while
# empty. Returns {"slot": the framed control to add, "holder": the Control to fill via _set_holder_card}.
func _make_card_slot(card_size: Vector2, placeholder: String) -> Dictionary:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = card_size
	slot.size_flags_horizontal = SIZE_SHRINK_CENTER
	slot.size_flags_vertical = SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	# Legible against the station's dark wood (was tuned for the old light chrome panel).
	sb.bg_color = Color(1, 1, 1, 0.10)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.32)
	slot.add_theme_stylebox_override("panel", sb)

	var holder := Control.new()
	holder.clip_contents = true
	holder.mouse_filter = MOUSE_FILTER_IGNORE
	slot.add_child(holder)

	var ph := Label.new()
	ph.name = "Placeholder"
	ph.text = placeholder
	ph.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ph.add_theme_font_size_override("font_size", 16)
	ph.add_theme_color_override("font_color", Color("5a4a38"))
	ph.mouse_filter = MOUSE_FILTER_IGNORE
	holder.add_child(ph)
	return {"slot": slot, "holder": holder}


# Puts `inst`'s card into a slot holder (or clears it back to the placeholder when null).
# `on_click` (when valid) fires when the slotted card is clicked/tapped — used to clear the slot.
func _set_holder_card(holder: Control, inst: CardInstance, on_click := Callable()) -> void:
	for c in holder.get_children():
		if c.name == "Placeholder":
			c.visible = inst == null
		else:
			c.queue_free()
	if inst != null:
		var ui := CardUI.create(inst)
		ui.draggable = false
		# Zero the scene's min size so the card scales DOWN to the slot instead of overflowing and
		# getting clipped (CardUI scales its canvas by width; the slot is sized to the card aspect).
		ui.custom_minimum_size = Vector2.ZERO
		ui.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		ui.mouse_filter = MOUSE_FILTER_STOP   # receives hover (its standard tooltip) and clicks (clear)
		if on_click.is_valid():
			ui.pressed.connect(on_click)
		holder.add_child(ui)


# Shows the selected charm as a large chip centred in a (card-shaped) slot; clicking it deselects
# the charm — matching the tap-a-slot-to-clear behaviour of the card slots.
func _set_holder_charm(holder: Control, charm_id: String) -> void:
	for c in holder.get_children():
		if c.name == "Placeholder":
			c.visible = false
		else:
			c.queue_free()
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	cc.mouse_filter = MOUSE_FILTER_IGNORE
	var d := _slot_size.x * 0.66
	var chip := _make_charm_chip(charm_id, 1, Vector2(d, d))
	chip.mouse_filter = MOUSE_FILTER_STOP   # clickable to deselect (+ its own charm tooltip on hover)
	chip.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
				and not (e as InputEventMouseButton).pressed:
			_clear_charm())
	cc.add_child(chip)
	holder.add_child(cc)


# THE single place that paints the right panel. It shows whichever pairing is current — a card+card
# COMBINE or a charm+card ENCHANT — sourced from either an in-flight drag or the click selection.
func _refresh_forge() -> void:
	var a_inst: CardInstance = null       # slot A card (null when slot A shows a charm instead)
	var a_charm := ""                     # slot A charm id ("" = slot A shows a card / placeholder)
	var b_inst: CardInstance = null       # slot B card
	var result_inst: CardInstance = null
	var status := ""
	var color := IDLE_COLOR
	var can_act := false                  # is the action button enabled
	var enchanting := false               # true = Enchant action, false = Combine
	var cost_i := -1                      # the previewed merge's Mineral cost (-1 = no valid pair)
	# Click-to-clear is only wired in the selection flow (set below); during a drag the slots show
	# transient drag/hover content and must not be clearable.
	var a_click := Callable()
	var b_click := Callable()

	if not _drag.is_empty() and _drag.get("kind") == "card":
		var di := int(_drag.get("idx", -1))
		if di >= 0 and di < _entries.size():
			a_inst = _entries[di].card.make_instance()
		if _hover_idx >= 0 and _hover_idx < _entries.size():
			b_inst = _entries[_hover_idx].card.make_instance()
			var verdict := _evaluate_target(_drag, _hover_idx)
			status = str(verdict.get("status", ""))
			color = verdict.get("color", IDLE_COLOR)
			if bool(verdict.get("ok", false)):
				result_inst = verdict.get("preview", null)
				cost_i = int(verdict.get("cost", -1))
		else:
			status = ""   # the room's metaphor carries the how-to; no instructional text
	elif not _drag.is_empty() and _drag.get("kind") == "charm":
		enchanting = true
		a_charm = str(_drag.get("id", ""))
		if _hover_idx >= 0 and _hover_idx < _entries.size():
			b_inst = _entries[_hover_idx].card.make_instance()
			var verdict := _evaluate_target(_drag, _hover_idx)
			status = str(verdict.get("status", ""))
			color = verdict.get("color", IDLE_COLOR)
			if bool(verdict.get("ok", false)):
				result_inst = verdict.get("preview", null)
		else:
			status = ""
	elif _sel_charm != "":
		# Enchant mode (click flow): charm in slot A, the tapped target card (kept in _sel_a) in slot B.
		enchanting = true
		a_charm = _sel_charm
		b_click = _clear_slot_a
		var charm := CharmData.get_charm(_sel_charm)
		var charm_name: String = charm.display_name if charm != null else _sel_charm
		if _sel_a >= 0 and _sel_a < _entries.size():
			b_inst = _entries[_sel_a].card.make_instance()
			var verdict := _evaluate_target({"kind": "charm", "id": _sel_charm}, _sel_a)
			status = str(verdict.get("status", ""))
			color = verdict.get("color", IDLE_COLOR)
			if bool(verdict.get("ok", false)):
				result_inst = verdict.get("preview", null)
				can_act = true
		else:
			status = "Tap a card to enchant it with %s." % charm_name
	else:
		# Combine mode (click flow): two selected cards.
		a_click = _clear_slot_a
		b_click = _clear_slot_b
		if _sel_a >= 0 and _sel_a < _entries.size():
			a_inst = _entries[_sel_a].card.make_instance()
		if _sel_b >= 0 and _sel_b < _entries.size():
			b_inst = _entries[_sel_b].card.make_instance()
		if a_inst != null and b_inst != null:
			var verdict := _evaluate_target({"kind": "card", "idx": _sel_a}, _sel_b)
			status = str(verdict.get("status", ""))
			color = verdict.get("color", IDLE_COLOR)
			if bool(verdict.get("ok", false)):
				result_inst = verdict.get("preview", null)
				_result_deck_card = verdict.get("result_dc", null)
				cost_i = int(verdict.get("cost", -1))
				# A valid pair still previews when unaffordable, but the button stays off.
				can_act = bool(verdict.get("affordable", true))
		elif a_inst != null or b_inst != null:
			status = ""
		else:
			status = ""

	if a_charm != "":
		_set_holder_charm(_slot_a, a_charm)
	else:
		_set_holder_card(_slot_a, a_inst, a_click)
	_set_holder_card(_slot_b, b_inst, b_click)
	_set_holder_card(_result_slot, result_inst)

	# The station's full result read: "Name (cost): rules text" — name bigger and cream, mana cost
	# in mana blue, so the header pops from the body. BBCode is hand-assembled here because
	# TextIcons.enrich escapes any brackets living in the SOURCE text.
	for c in _result_info.get_children():
		c.queue_free()
	if result_inst != null:
		var d: CardData = result_inst.data
		var lbl := TextIcons.rich_label("", 28, Color(0.93, 0.90, 0.84))
		lbl.size_flags_horizontal = SIZE_EXPAND_FILL
		_apply_result_text(lbl, d, 28)
		_result_info.add_child(lbl)
		_shrink_result_text(lbl, d)

	# The result's activated abilities as small tray-style tokens beside the text — the same visual
	# the tooltip/tray use, so "this is an ability" reads identically everywhere. Info-only here.
	for c in _ability_strip.get_children():
		c.queue_free()
	if result_inst != null:
		for ab: AbilityData in result_inst.ability_list():
			var tok := CardInstance.from_data(ab.display_card())
			tok.owner = 0
			tok.row = -1
			tok.col = -1
			tok.source_building = result_inst
			tok.ability = ab
			var w := AbilityWidget.create_for(tok)
			w.custom_minimum_size = Vector2(84, 110)
			w.size_flags_vertical = SIZE_SHRINK_CENTER
			w.mouse_filter = MOUSE_FILTER_IGNORE
			w.draggable = false
			_ability_strip.add_child(w)

	_preview_status.text = status
	_preview_status.visible = not status.is_empty()   # an empty line must not reserve height
	_preview_status.add_theme_color_override("font_color", color.lightened(0.15))
	# The merge price rides the action button itself — the decision and its cost in one place.
	if enchanting:
		_combine_btn.text = "Enchant"
	else:
		_combine_btn.text = "Combine" if cost_i < 0 else "Combine — %d Mineral" % cost_i
	_combine_btn.disabled = not can_act

	# Swirl the two ingredient slots whenever a valid COMBINE is previewed (never for enchant, which
	# has no "two cards fusing" read). Slots A/B are stable holders, so the FX just tracks their rects.
	_update_panel_fx(result_inst if not enchanting else null, a_inst, b_inst)
	_update_card_dimming()


# Grays out the deck cards the CURRENT source can't pair with, so valid targets read at a glance.
# The source is the in-flight drag, the selected charm, or a lone filled combine slot; with no
# source (or a completed pair) every card returns to full strength. Runs on every panel repaint —
# drag start/end and selection changes all funnel through _refresh_forge.
func _update_card_dimming() -> void:
	var payload: Dictionary = {}
	if not _drag.is_empty():
		payload = _drag
	elif _sel_charm != "":
		payload = {"kind": "charm", "id": _sel_charm}
	elif _sel_a >= 0 and _sel_b < 0:
		payload = {"kind": "card", "idx": _sel_a}
	elif _sel_b >= 0 and _sel_a < 0:
		payload = {"kind": "card", "idx": _sel_b}
	var src := int(payload.get("idx", -1)) if payload.get("kind", "") == "card" else -1
	for i in _entries.size():
		var item: Control = _entries[i].item
		if item == null:
			continue
		if not _drag.is_empty() and _drag.get("kind") == "card" and i == int(_drag.get("idx", -1)):
			continue   # the dragged source keeps its stronger ghost dim (set in _begin_drag)
		var dim := not payload.is_empty() and i != src and not _can_pair(payload, i)
		item.modulate.a = 0.35 if dim else 1.0


# Whether the payload could pair with the card at `idx` — combine within the composition limits,
# or a charm the card can bear and doesn't already. Structure only: affordability never grays a
# card (the status line carries the cost verdict).
func _can_pair(payload: Dictionary, idx: int) -> bool:
	var data: CardData = _entries[idx].data
	if payload.get("kind", "") == "card":
		var src := int(payload.get("idx", -1))
		if src < 0 or src >= _entries.size():
			return true
		return CardData.can_combine(_entries[src].data, data)
	var charm := CharmData.get_charm(str(payload.get("id", "")))
	if charm == null:
		return false
	return charm.can_attach_to(data) and str(payload.get("id", "")) not in (_entries[idx].card as DeckCard).charms


# Writes the result read at `body_size`: "Name (cost): rules" — name a step larger and cream,
# mana cost in mana blue, so the header pops from the body. BBCode is hand-assembled because
# TextIcons.enrich escapes any brackets living in the SOURCE text.
func _apply_result_text(lbl: RichTextLabel, d: CardData, body_size: int) -> void:
	lbl.add_theme_font_size_override("normal_font_size", body_size)
	var head := "[font_size=%d][color=#f5e9c9]%s[/color][/font_size] [color=#8fd0ff](%d)[/color]" \
			% [body_size + 4, d.display_name, d.cost]
	var body := TextIcons.enrich(d.description, body_size)
	lbl.text = head + (": " + body if not d.description.is_empty() else "")


# The band is fixed-height, so the read starts BIG and steps its font down until the MEASURED
# content height fits the box — it always compresses to fit, never scrolls (the floor is small
# enough that only an absurdly long description would ever bottom out there). Async: measures
# need a frame of layout; the label guard covers panel repaints that free it mid-loop.
func _shrink_result_text(lbl: RichTextLabel, d: CardData) -> void:
	var size := 28
	await get_tree().process_frame
	while is_instance_valid(lbl) and _result_text_box != null and size > 8 \
			and float(lbl.get_content_height()) + _status_height() > _result_text_box.size.y:
		size -= 2
		_apply_result_text(lbl, d, size)
		await get_tree().process_frame


# The box height the status line takes away from the result read (it shares the text box).
func _status_height() -> float:
	if _preview_status == null or not _preview_status.visible:
		return 0.0
	return _preview_status.get_combined_minimum_size().y


# A press on a deck card / charm: held as pending until release (tap) or movement (drag).
func _on_press(payload: Dictionary) -> void:
	if not _drag.is_empty() or not _pending.is_empty():
		return
	_pending = payload
	_press_pos = get_global_mouse_position()


# A tap (press+release without dragging). A charm tap toggles ENCHANT mode; a card tap either picks
# the enchant target (in enchant mode) or fills the combine slots.
func _on_tap(payload: Dictionary) -> void:
	if payload.get("kind") == "charm":
		var cid := str(payload.get("id", ""))
		if _sel_charm == cid:
			_sel_charm = ""          # tapping the selected charm again cancels enchant mode
		else:
			_sel_charm = cid         # enter enchant mode; keep _sel_a as the target, drop the 2nd card
			_sel_b = -1
		_update_selection_highlights()
		_refresh_forge()
		return

	var idx := int(payload.idx)
	if _sel_charm != "":
		# Enchant mode: the tapped card is the single target (kept in _sel_a).
		_sel_a = -1 if _sel_a == idx else idx
	elif idx == _sel_a:
		_sel_a = -1
	elif idx == _sel_b:
		_sel_b = -1
	elif _sel_a < 0:
		_sel_a = idx
	elif _sel_b < 0:
		_sel_b = idx
	else:
		_sel_b = idx   # both slots full — replace the second ingredient
	_update_selection_highlights()
	_refresh_forge()


func _update_selection_highlights() -> void:
	for i in _entries.size():
		var ui: CardUI = _entries[i].ui
		if ui != null:
			ui.set_selected(i == _sel_a or i == _sel_b)
	# Brighten the selected charm chip on the shelf, dim the rest, so the active charm reads.
	for child in _charm_col.get_children():
		if child is ForgeDragItem:
			var cid: String = str((child as ForgeDragItem).payload.get("id", ""))
			child.modulate = Color(1.25, 1.25, 1.25) if cid == _sel_charm else Color.WHITE


# Clicking a filled ingredient slot empties it (the deck card un-highlights and frees up the slot).
func _clear_slot_a() -> void:
	_sel_a = -1
	_update_selection_highlights()
	_refresh_forge()


func _clear_slot_b() -> void:
	_sel_b = -1
	_update_selection_highlights()
	_refresh_forge()


func _clear_charm() -> void:
	_sel_charm = ""
	_update_selection_highlights()
	_refresh_forge()


# The action button: enchant the selected card with the selected charm, or fuse the selected pair.
# Combining from the panel skips the confirm modal (the panel already previews A+B→result) and plays
# the fusion right on the slot cards; the destructive-action gate is the drag-drop path's job.
func _on_combine_pressed() -> void:
	if _sel_charm != "":
		if _sel_a < 0:
			return
		var ev := _evaluate_target({"kind": "charm", "id": _sel_charm}, _sel_a)
		if not bool(ev.get("ok", false)):
			return
		_do_enchant(_sel_charm, _sel_a)
		return
	if _sel_a < 0 or _sel_b < 0:
		return
	var verdict := _evaluate_target({"kind": "card", "idx": _sel_a}, _sel_b)
	if not bool(verdict.get("ok", false)) or not bool(verdict.get("affordable", true)):
		return
	_start_panel_fusion(_sel_a, _sel_b, verdict.get("result_dc", null))


# ── Apply ──────────────────────────────────────────────────────────────────────

func _do_combine(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	if result_dc == null or src_idx < 0:
		return
	# The mineral spend — recomputed here (the single commit point for both the modal and the
	# panel path) so it can never drift from what the preview quoted. Every route in already
	# gated on affordability; the guard is belt-and-braces against a stale UI.
	var cost := ForgeCosts.merge_cost(_entries[src_idx].data as CardData,
			_entries[tgt_idx].data as CardData)
	if GameData.current_run.magic_mineral < cost:
		return
	GameData.current_run.magic_mineral -= cost
	var src_deck: int = int(_entries[src_idx].deck_idx)
	var tgt_deck: int = int(_entries[tgt_idx].deck_idx)
	# Remove both source cards highest-deck-index-first to avoid index shifting.
	var deck_indices := [src_deck, tgt_deck]
	deck_indices.sort()
	for i in range(deck_indices.size() - 1, -1, -1):
		GameData.current_run.deck.remove_at(deck_indices[i])
	# Drop the result into the TARGET card's slot (shift left one if the source sat before it).
	var insert_at := tgt_deck - (1 if src_deck < tgt_deck else 0)
	insert_at = clampi(insert_at, 0, GameData.current_run.deck.size())
	GameData.current_run.deck.insert(insert_at, result_dc)
	GameData.save_run()
	Sfx.combined()
	_rebuild_deck()


func _do_enchant(charm_id: String, tgt_idx: int) -> void:
	var dc: DeckCard = _entries[tgt_idx].card
	var data: CardData = _entries[tgt_idx].data
	dc.add_charm(charm_id)
	GameData.current_run.charms.erase(charm_id)
	GameData.save_run()
	Sfx.combined()
	_rebuild_deck()
	_rebuild_charms()
	# _rebuild_deck refreshed the panel to the idle prompt; overwrite with the success message.
	_preview_status.text = "Enchanted %s with %s!" % [data.display_name, CharmData.get_charm(charm_id).display_name]
	_preview_status.visible = true
	_preview_status.add_theme_color_override("font_color", OK_COLOR)


# ── Particles ──────────────────────────────────────────────────────────────────

# Half-extents of the particle path. Start from the card's half-size, scale it by
# ForgeFX.AURA.radius_scale (the main handle — 1.0 = on the edge, >1 = wider, <1 = tighter), then
# add ForgeFX.AURA.margin for a flat px nudge on top. Tweak `radius_scale` to resize the ring.
func _card_aura_radii() -> Vector2:
	var scale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	return Vector2(_card_size.x * 0.5 * scale + margin, _card_size.y * 0.5 * scale + margin)


func _aura_radii(payload: Dictionary) -> Vector2:
	if payload.kind == "card":
		return _card_aura_radii()
	var scale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	var r := _charm_follower_size().x * 0.5   # match the (enlarged) charm follower
	return Vector2(r * scale + margin, r * scale + margin)


# Shows/updates/hides the merge swirl over slots A+B. Painted only when a valid combine is queued
# (result != null and both ingredients present); keyed on the pair so a mere panel repaint doesn't
# respawn identical FX (which would restart the swirl every hover flicker / status change).
func _update_panel_fx(result_inst: CardInstance, a_inst: CardInstance, b_inst: CardInstance) -> void:
	var key := ""
	if result_inst != null and a_inst != null and b_inst != null:
		key = a_inst.data.id + "|" + b_inst.data.id
	if key == _panel_fx_key:
		return
	_panel_fx_key = key
	if _panel_fx != null:
		_panel_fx.queue_free()
		_panel_fx = null
	if key == "":
		return
	_panel_fx = ForgeMergeFX.new()
	_overlay.add_child(_panel_fx)
	_panel_fx.bind(_slot_a, _slot_b, _color_for_card(a_inst.data), _color_for_card(b_inst.data), OK_COLOR)


# A hand-drawn halo that swirls around the card — see ForgeAura (tuning in ForgeFX.AURA).
func _make_aura(color: Color, rx: float, ry: float) -> ForgeAura:
	var a := ForgeAura.new()
	a.setup(rx, ry, color)
	return a


func _source_color(payload: Dictionary) -> Color:
	if payload.kind == "card":
		return _color_for_card(_entries[int(payload.idx)].data)
	var charm := CharmData.get_charm(str(payload.id))
	return charm.color if charm != null else Color(0.8, 0.7, 1.0)


# The aura tint for a card — its first element's colour, falling back to its first chess piece, then
# a neutral blue. Shared by the drag source aura and the static merge FX (modal + side panel).
func _color_for_card(data: CardData) -> Color:
	if not data.elements.is_empty():
		var info: Dictionary = CardUI.COMP_VISUALS.get(data.elements[0], {})
		return info.get("color", Color(0.7, 0.8, 1.0))
	if not data.chess_pieces.is_empty():
		var cinfo: Dictionary = CardUI.COMP_VISUALS.get(data.chess_pieces[0], {})
		return cinfo.get("color", Color(0.7, 0.8, 1.0))
	return Color(0.7, 0.8, 1.0)


func _leave() -> void:
	Nav.goto("res://scenes/map.tscn")
