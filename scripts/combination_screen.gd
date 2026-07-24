extends Control

# The CRAFTING screen (map "forge" nodes) — standard Shell chrome (title + Mineral chip in the
# header, footer Back). The deck spread IS the whole workspace: cards fill the body, charms live
# on a left-edge bar, and there is no side station. Combining and enchanting share ONE in-place
# grammar:
#   pick a source (card or charm) → pick a target card → the target TRANSFORMS into the result
#   right on its grid spot: enlarged + radiant, wrapped by a framing that shows the two
#   components on its left and the result's full read on its right, with Cancel + Combine/Attach
#   buttons beneath. The button is the single commit point; tapping the dimmed table,
#   right-click or Esc cancels.
# Both input styles feed the same funnel:
#  • Tap/click: tap a source card (or charm), then tap the target card.
#  • Drag: drag a card/charm onto a target; the drag keeps the full polish (particle aura,
#    wobble, the vortex linking it to a valid target — VFX in ForgeFX), and the drop opens the
#    same merge framing.
# On a touch device a dragged charm lifts above the finger (which would otherwise hide it), with
# the hit-test following the chip; on desktop it stays centred on the cursor at its normal size.

# One entry per deck card: { "card": DeckCard, "deck_idx": int, "data": CardData, "ui": CardUI,
# "item": ForgeDragItem, "combinable": bool (false = can't source a merge, still an enchant target) }
var _entries: Array = []

# Must match the CardUI root custom_minimum_size in scenes/card_ui.tscn so the deck grid scales.
const CARD_SIZE := Vector2(160, 210)
# Native card aspect (260×340) — _fit_cards sizes the table grid with it.
const CARD_ASPECT := 340.0 / 260.0
# All particle VFX tuning lives in ForgeFX (ForgeFX.AURA / ForgeFX.LINK).

const OK_COLOR   := Color(0.4, 1.0, 0.55)
const BAD_COLOR  := Color(1.0, 0.4, 0.4)

const DRAG_THRESHOLD := 12.0   # px the pointer must travel before a press becomes a drag (vs a tap)
# The deck grid's BASE gap. _fit_cards inflates the live separations above this to absorb the
# fit remainder — never read the separation back from the grid (it returns the inflated value).
const GRID_SEP := 16.0
# Reserved lanes above and below the card spread — guaranteed room for the selection tips (the
# "pick a target" pill above the highlighted card, the cancel hint below it), so they NEVER have
# to fold onto the cards even for edge rows.
const TIP_LANE := 56.0

var _deck_grid: GridContainer
var _scroll: ScrollContainer
var _charm_col: VBoxContainer
var _card_size := CARD_SIZE
const CHARM_SIZE := Vector2(82, 82)

# Each "this is live" state is TWO cues, one light: an outer glow spilling past the edge and a
# dim inner luminescence, breathing on the same period. Both ride shape-sourced RenderFilters —
# the commit button is drawn procedurally and the result holder holds a composed CardUI scene, so
# neither has a texture whose alpha a filter could read; their real rounded-rect shape is the
# silhouette instead.
const COMBINE_READY_CUES := ["forge_combine_ready_glow", "forge_combine_ready_inner"]
const RESULT_READY_CUES := ["forge_result_radiance", "forge_result_inner"]

# The current SOURCE pick: {"kind":"card","idx":int} or {"kind":"charm","id":String}; {} = none.
var _sel: Dictionary = {}
# The widget currently wearing the canonical selection Highlight (grow + outline + glow — see
# HighlightFx / the `highlight` vfx entry); null = none.
var _hl_item: Control = null
# Floating tips riding OUTSIDE the highlighted source, tracked to it every frame in _process:
# above it, what to do next ("Pick another card to merge" / the enchant equivalent); below it,
# how to back out ("Right click to cancel"). The spread reserves TIP_LANE for each.
var _sel_tip: PanelContainer = null
var _sel_tip_label: Label = null
var _cancel_tip: PanelContainer = null

# The open merge procedure ({} = closed): {"src": payload, "tgt": entry idx, "verdict": Dictionary}.
var _merge: Dictionary = {}
var _modal: Control = null          # the dim backdrop — also hosts the fusion anim + result toast
var _cluster: Control = null        # the framing cluster (freed on commit, before the fusion)
var _comp_holders: Array = []       # the two component visuals — the fusion's fly-from points
var _result_holder: Control = null  # the enlarged result card's holder (wears the radiance cues)
var _commit_btn: Button = null
# Fusion-animation state, live only between hitting Combine and dismissing the result toast. While
# _fusing is true the modal dim ignores clicks/Esc so the sequence can't be cut off mid-flight.
var _fusing := false
var _fuse_anim: ForgeFuseAnim = null

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


func _ready() -> void:
	Sfx.music("music_forge")
	_build_ui()
	_rebuild_deck()
	_rebuild_charms()


func get_chrome() -> Dictionary:
	# Standard chrome: the header carries the Mineral chip (the only run stat that matters here)
	# and the ✕; the footer carries Back. The OS back gesture / Esc first cancels an open merge.
	# inset: false — the table is full-bleed art (like the map); the Shell's shared menu margins
	# would compress it into a floating panel. Header/footer stay as their own rows regardless.
	return {"title": Loc.t("combine.title"), "fields": [ScreenUI.Field.MINERAL],
		"exit": _leave, "back": _back_or_cancel, "show_footer": true, "inset": false}


# OS back / Esc: an open merge closes back to the table first; otherwise leave the room.
func _back_or_cancel() -> void:
	if _modal != null:
		if not _fusing:
			_close_modal()
		return
	_leave()


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

	# ── Body: [charm bar] · [card table] ─────────────────────────────────────────
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)   # keep content off the table's rim art
	add_child(pad)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	pad.add_child(body)

	# Left edge: the charm bar — a slim vertical rail of draggable charm chips. Everything on it
	# is a drag SOURCE, never a drop target, so a flicked drag can't end there.
	var bar := PanelContainer.new()
	bar.size_flags_vertical = SIZE_EXPAND_FILL
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0, 0, 0, 0.30)
	bar_style.set_corner_radius_all(12)
	bar_style.set_content_margin_all(10)
	bar.add_theme_stylebox_override("panel", bar_style)
	body.add_child(bar)

	var bar_scroll := ScrollContainer.new()
	bar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	bar_scroll.custom_minimum_size.x = CHARM_SIZE.x
	bar.add_child(bar_scroll)
	_charm_col = VBoxContainer.new()
	_charm_col.size_flags_horizontal = SIZE_EXPAND_FILL
	_charm_col.size_flags_vertical = SIZE_EXPAND_FILL
	_charm_col.alignment = BoxContainer.ALIGNMENT_CENTER   # chips ride mid-rail, not top-stuck
	_charm_col.add_theme_constant_override("separation", 12)
	bar_scroll.add_child(_charm_col)

	# The card table — the whole deck, fit-to-space (see _fit_cards).
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	# SHOW_NEVER (not DISABLED): the fitted grid's min width must NOT propagate up, or it deadlocks
	# the HBox after _fit_cards sizes the cards.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.resized.connect(_fit_cards)
	body.add_child(scroll)
	_scroll = scroll

	# The fitted spread is usually a touch narrower than the viewport (whole columns only) — the
	# wrap centres it so the leftover reads as even table margin, not a dead strip on one side
	# (ScrollContainer itself pins its child top-left regardless of shrink flags).
	# The tip lanes: fixed top/bottom margins keeping the spread clear of the floating selection
	# pills (see TIP_LANE). _fit_cards subtracts them from its height budget.
	var grid_pad := MarginContainer.new()
	grid_pad.size_flags_horizontal = SIZE_EXPAND_FILL
	grid_pad.size_flags_vertical = SIZE_EXPAND_FILL
	grid_pad.add_theme_constant_override("margin_top", int(TIP_LANE))
	grid_pad.add_theme_constant_override("margin_bottom", int(TIP_LANE))
	scroll.add_child(grid_pad)
	var grid_wrap := VBoxContainer.new()
	grid_wrap.size_flags_horizontal = SIZE_EXPAND_FILL
	grid_wrap.size_flags_vertical = SIZE_EXPAND_FILL
	grid_wrap.alignment = BoxContainer.ALIGNMENT_CENTER   # small decks sit mid-table, not top-stuck
	grid_pad.add_child(grid_wrap)
	_deck_grid = GridContainer.new()
	_deck_grid.columns = 4
	_deck_grid.add_theme_constant_override("h_separation", int(GRID_SEP))
	_deck_grid.add_theme_constant_override("v_separation", int(GRID_SEP))
	_deck_grid.size_flags_horizontal = SIZE_SHRINK_CENTER
	grid_wrap.add_child(_deck_grid)

	# Drag overlay: floats above everything, never eats input.
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_overlay)

	# The selection tips: dark pills floating just above and below the highlighted source
	# card/chip — never over the card itself (the spread's TIP_LANE margins guarantee the room).
	_sel_tip = _make_tip_pill(22, Color(0.98, 0.97, 0.92), 0.66)
	_sel_tip_label = _sel_tip.get_child(0) as Label
	_overlay.add_child(_sel_tip)
	var cancel_pill := _make_tip_pill(19, Color(0.88, 0.86, 0.80), 0.55)
	(cancel_pill.get_child(0) as Label).text = Loc.t("combine.cancel_hint")
	_overlay.add_child(cancel_pill)
	_cancel_tip = cancel_pill


# A floating hint pill (dark rounded backdrop + one label), hidden until a selection shows it.
func _make_tip_pill(font_size: int, font_color: Color, bg_alpha: float) -> PanelContainer:
	var pill := PanelContainer.new()
	pill.mouse_filter = MOUSE_FILTER_IGNORE
	pill.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, bg_alpha)
	style.set_corner_radius_all(10)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	pill.add_theme_stylebox_override("panel", style)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", font_color)
	pill.add_child(lbl)
	return pill


# ── Deck display ────────────────────────────────────────────────────────────────

# Fit-all: pick the column count that shows the WHOLE deck at the largest card size (native
# aspect) — deck sizes are bounded, so scrolling here is pointless (user directive) and stays a
# floor-degradation path only. Ties prefer fewer remainder holes, then the wider spread.
func _fit_cards() -> void:
	if _scroll == null or _deck_grid == null or _entries.is_empty():
		return
	var avail := _scroll.size
	avail.y = maxf(avail.y - TIP_LANE * 2.0, 50.0)   # the tip lanes are off the grid's budget
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


func _rebuild_deck() -> void:
	_cancel_drag()
	for child in _deck_grid.get_children():
		child.queue_free()
	_entries.clear()
	_sel = {}
	_hl_item = null   # its wearer is being freed; the attach auto-detaches on tree_exiting

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

		# Every card is wrapped so it can be a drop TARGET (rect hit-test) and receive taps (a
		# charm's enchant target); only combinable cards can SOURCE a merge (drag or first tap).
		var item := ForgeDragItem.new()
		item.custom_minimum_size = _card_size
		item.setup(ui, {"kind": "card", "idx": _entries.size()})
		# Hover detail comes from the CardUI's OWN standard tooltip (ForgeDragItem leaves the card on
		# MOUSE_FILTER_PASS) — the same path the rest of the game uses; nothing bespoke here.
		item.grab.connect(_on_press)

		_entries.append({ "card": dc, "deck_idx": i, "data": data, "ui": ui, "item": item,
			"combinable": combinable })
		_deck_grid.add_child(item)

	_fit_cards()   # deck count changed — resize the table's cards to fit the new spread
	_update_selection_highlights()
	_update_card_dimming()


# ── Charm inventory ──────────────────────────────────────────────────────────────

func _rebuild_charms() -> void:
	for child in _charm_col.get_children():
		child.queue_free()

	var counts: Dictionary = {}
	for charm_id: String in GameData.current_run.charms:
		counts[charm_id] = int(counts.get(charm_id, 0)) + 1

	if counts.is_empty():
		var empty := Label.new()
		empty.text = Loc.t("combine.no_charms")
		empty.custom_minimum_size.x = CHARM_SIZE.x
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 18)
		empty.add_theme_color_override("font_color", Color(0.9, 0.85, 0.75, 0.6))
		_charm_col.add_child(empty)
		return

	for charm_id: String in counts:
		_charm_col.add_child(_make_charm_item(charm_id, counts[charm_id]))


# A draggable charm chip (with ×N count). Dropping/tapping it onto a card opens the Attach merge.
func _make_charm_item(charm_id: String, count: int) -> ForgeDragItem:
	var size := CHARM_SIZE
	var item := ForgeDragItem.new()
	item.custom_minimum_size = size
	# Fixed square badge centred in the bar's width.
	item.size_flags_horizontal = SIZE_SHRINK_CENTER
	item.setup(_make_charm_chip(charm_id, count, size), {"kind": "charm", "id": charm_id})
	var charm := CharmData.get_charm(charm_id)
	if charm != null:
		UIScale.tip(item, "%s — %s" % [charm.display_name, charm.description])
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
		UIScale.tip(chip, "%s — %s" % [charm.display_name, charm.description])

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

	var visual: Control = _make_follower_visual(payload)
	var half := visual.custom_minimum_size * 0.5
	_follower = Control.new()
	_follower.mouse_filter = MOUSE_FILTER_IGNORE
	# Cards always centre on the pointer. A charm centres on the pointer on desktop (a mouse cursor
	# occludes nothing), but on a TOUCH device it lifts above the finger — a chip under a fingertip
	# is invisible while dragging. When lifted, the hit-test and the vortex follow the chip's
	# centre via _follower_center (see _update_drag).
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

	_update_selection_highlights()   # hides the selection tip while the drag is in flight
	_update_card_dimming()           # gray out what this source can't pair with
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


# The dragged charm chip's size. Touch visibility is handled by LIFTING the chip above the finger
# (see _begin_drag), not by enlarging it; desktop needs neither.
func _charm_follower_size() -> Vector2:
	return Vector2(64, 64)


# Keeps the floating tips glued to the highlighted source — above (what to do) and below (how to
# cancel). The source moves under them (scroll, refit, the highlight's own grow animation), so
# they follow every frame they're shown. The spread's TIP_LANE margins guarantee the room; the
# clamps here are only a spill guard, never a re-flow.
func _track_sel_tip() -> void:
	if _sel_tip == null or not _sel_tip.visible or _hl_item == null or not is_instance_valid(_hl_item):
		return
	var r := _hl_item.get_global_rect()   # transform-aware: tracks the grown (scaled) card
	var ov := _overlay.get_global_rect()
	var sz := _sel_tip.size
	var pos := Vector2(r.get_center().x - sz.x * 0.5, r.position.y - sz.y - 10.0)
	pos.x = clampf(pos.x, 6.0, ov.end.x - sz.x - 6.0)
	pos.y = maxf(pos.y, ov.position.y + 6.0)
	_sel_tip.global_position = pos
	var csz := _cancel_tip.size
	var cpos := Vector2(r.get_center().x - csz.x * 0.5, r.end.y + 10.0)
	cpos.x = clampf(cpos.x, 6.0, ov.end.x - csz.x - 6.0)
	cpos.y = minf(cpos.y, ov.end.y - csz.y - 6.0)
	_cancel_tip.global_position = cpos


# Drives the dragged card's wobble: it eases in while a link is active, out when it breaks.
func _process(delta: float) -> void:
	_track_sel_tip()
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
	# While the merge modal is up, swallow input here (Esc cancels it) so a stray tap/drag
	# can't reshuffle the deck behind it and Nav doesn't also fire.
	if _modal != null:
		if event.is_action_pressed("ui_cancel"):
			if not _fusing:            # mid-fusion Esc is swallowed but must NOT abort the sequence
				_close_modal()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		if not _drag.is_empty():
			_update_drag(get_global_mouse_position())
		elif not _pending.is_empty() and get_global_mouse_position().distance_to(_press_pos) > DRAG_THRESHOLD:
			# Moved past the threshold — promote the pending press into a real drag. Non-combinable
			# cards never drag (they can't source a merge); their press can still resolve as a tap
			# (an enchant target under a selected charm).
			var p := _pending
			if p.get("kind") == "card" and not bool(_entries[int(p.idx)].combinable):
				return
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
			elif not _sel.is_empty():
				# A click that never grabbed a card or charm — empty table, rail, any dead space —
				# drops the selection back to the clean grid.
				_sel = {}
				_update_selection_highlights()
				_update_card_dimming()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if not _drag.is_empty():
				_cancel_drag()   # right-click aborts the drag without merging
				get_viewport().set_input_as_handled()
			elif not _pending.is_empty():
				_pending = {}
			elif not _sel.is_empty() and _target_under(get_global_mouse_position()) < 0:
				# Right-click on dead space drops the selection. ON a card the event falls
				# through untouched to the GUI, where CardUI opens the full CardInspector —
				# right-click = card details, the same language as everywhere else.
				_sel = {}
				_update_selection_highlights()
				_update_card_dimming()
				get_viewport().set_input_as_handled()


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
		return

	var verdict := _evaluate_target(_drag, target_idx)
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


# A drop on a valid target opens the SAME merge framing as the tap flow — the drop never commits
# anything by itself.
func _resolve_drag() -> void:
	var payload := _drag
	var hover := _hover_idx
	var verdict: Dictionary = _evaluate_target(payload, hover) if hover >= 0 else {}
	_cancel_drag()
	if hover >= 0 and bool(verdict.get("ok", false)):
		_open_merge(payload, hover, verdict)


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
	_update_selection_highlights()   # the tip returns if a click-selection is still active
	_update_card_dimming()


# ── Validity + preview ──────────────────────────────────────────────────────────

# Evaluates pairing `payload` with the card at `target_idx`. Returns:
#   { ok, status, color, preview: CardInstance|null, result_dc: DeckCard|null,
#     affordable, cost (combine only) }
func _evaluate_target(payload: Dictionary, target_idx: int) -> Dictionary:
	var tgt: Dictionary = _entries[target_idx]
	if payload.kind == "card":
		var a: CardData = _entries[int(payload.idx)].data
		var b: CardData = tgt.data
		if not CardData.can_combine(a, b):
			return {"ok": false, "status": Loc.t("combine.status_limit"), "color": BAD_COLOR}
		var result := CardData.combine(a, b)
		var rdc := DeckCard.make(result.id)
		for charm_id: String in _merged_parent_charms([_entries[int(payload.idx)].card, tgt.card], result):
			rdc.add_charm(charm_id)
		# Merging costs Magic Mineral (see ForgeCosts). An unaffordable pair still previews its
		# result (ok stays true) but can't be forged — the commit button gates on "affordable".
		var cost := ForgeCosts.merge_cost(a, b)
		var have: int = GameData.current_run.magic_mineral if GameData.current_run != null else 0
		if have < cost:
			return {"ok": true, "affordable": false, "cost": cost,
				"status": Loc.t("combine.status_need_mineral", {"cost": cost, "have": have}),
				"color": BAD_COLOR, "preview": rdc.make_instance(), "result_dc": rdc}
		# Affordable: the cost renders on the commit button itself — no status text needed.
		return {"ok": true, "affordable": true, "cost": cost, "status": "",
			"color": OK_COLOR, "preview": rdc.make_instance(), "result_dc": rdc}
	else:
		var charm := CharmData.get_charm(str(payload.id))
		var data: CardData = tgt.data
		if charm == null:
			return {"ok": false}
		if not charm.can_attach_to(data):
			return {"ok": false, "status": Loc.t("combine.status_cant_bear", {"card": data.display_name, "charm": charm.display_name}), "color": BAD_COLOR}
		if str(payload.id) in (tgt.card as DeckCard).charms:
			return {"ok": false, "status": Loc.t("combine.status_already", {"card": data.display_name, "charm": charm.display_name}), "color": BAD_COLOR}
		var preview_dc := (tgt.card as DeckCard).clone()
		preview_dc.add_charm(str(payload.id))
		return {"ok": true, "status": "", "color": OK_COLOR, "preview": preview_dc.make_instance()}


# Union of both parents' charms still valid on the combined result.
func _merged_parent_charms(parents: Array, result_card: CardData) -> Array:
	var out: Array = []
	for dc: DeckCard in parents:
		for charm_id: String in dc.charms:
			var charm := CharmData.get_charm(charm_id)
			if charm != null and charm.can_attach_to(result_card) and charm_id not in out:
				out.append(charm_id)
	return out


# Whether the payload could pair with the card at `idx` — combine within the composition limits,
# or a charm the card can bear and doesn't already. Structure only: affordability never grays a
# card (the merge framing carries the cost verdict).
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


# ── Selection (tap flow) ────────────────────────────────────────────────────────

# A press on a deck card / charm: held as pending until release (tap) or movement (drag).
func _on_press(payload: Dictionary) -> void:
	if _modal != null or not _drag.is_empty() or not _pending.is_empty():
		return
	_pending = payload
	_press_pos = get_global_mouse_position()


# A tap (press+release without dragging). The first tap picks the SOURCE (card or charm); the
# second tap picks the TARGET card and — when the pairing is valid — opens the merge framing.
func _on_tap(payload: Dictionary) -> void:
	if payload.get("kind") == "charm":
		var cid := str(payload.get("id", ""))
		if _sel.get("kind", "") == "charm" and str(_sel.get("id", "")) == cid:
			_sel = {}                          # tapping the selected charm again deselects it
		else:
			_sel = {"kind": "charm", "id": cid}
		_update_selection_highlights()
		_update_card_dimming()
		return

	var idx := int(payload.idx)
	if _sel.is_empty():
		if bool(_entries[idx].combinable):     # non-combinable cards can't source a merge
			_sel = {"kind": "card", "idx": idx}
	elif _sel.get("kind", "") == "card" and int(_sel.get("idx", -1)) == idx:
		_sel = {}                              # tapping the source again deselects it
	else:
		var verdict := _evaluate_target(_sel, idx)
		if bool(verdict.get("ok", false)):
			_open_merge(_sel, idx, verdict)
			return
		elif bool(_entries[idx].combinable):
			_sel = {"kind": "card", "idx": idx}   # invalid pairing — reseat the selection here
	_update_selection_highlights()
	_update_card_dimming()


# The selected source — card or charm chip alike — wears the canonical Highlight treatment
# (grow + white outline + glow, all tool-tunable on the `highlight` vfx entry). One language
# for "this is picked", here and (soon) in combat. While the merge modal is up the SELECTION
# persists but the treatment is suppressed (the highlight lives on the overlay layer, which
# draws ABOVE the modal dim — it would glow through); closing the modal restores it.
func _update_selection_highlights() -> void:
	var want: Control = null
	if _modal == null:
		if _sel.get("kind", "") == "card":
			var idx := int(_sel.get("idx", -1))
			if idx >= 0 and idx < _entries.size():
				want = _entries[idx].item
		elif _sel.get("kind", "") == "charm":
			var cid := str(_sel.get("id", ""))
			for child in _charm_col.get_children():
				if child is ForgeDragItem and str((child as ForgeDragItem).payload.get("id", "")) == cid:
					want = child
					break
	if want != _hl_item:
		if _hl_item != null and is_instance_valid(_hl_item):
			Vfx.detach("highlight", _hl_item)
		_hl_item = want
		if want != null:
			Vfx.attach("highlight", want)
	# The floating tips ride with the highlight (hidden mid-drag — the drag IS the affordance).
	var show_tip := want != null and _drag.is_empty()
	_sel_tip.visible = show_tip
	_cancel_tip.visible = show_tip
	if show_tip:
		if _sel.get("kind", "") == "charm":
			var charm := CharmData.get_charm(str(_sel.get("id", "")))
			_sel_tip_label.text = Loc.t("combine.tap_to_enchant",
					{"charm": charm.display_name if charm != null else ""})
		else:
			_sel_tip_label.text = Loc.t("combine.pick_target")
		_track_sel_tip()


# Grays out the deck cards the CURRENT source can't pair with, so valid targets read at a glance.
# The source is the in-flight drag or the tap selection; with no source, only the structurally
# inert (non-combinable) cards stay dimmed.
func _update_card_dimming() -> void:
	var payload: Dictionary = _drag if not _drag.is_empty() else _sel
	var src := int(payload.get("idx", -1)) if payload.get("kind", "") == "card" else -1
	for i in _entries.size():
		var e: Dictionary = _entries[i]
		var item: Control = e.item
		if item == null:
			continue
		if not _drag.is_empty() and _drag.get("kind") == "card" and i == int(_drag.get("idx", -1)):
			continue   # the dragged source keeps its stronger ghost dim (set in _begin_drag)
		var dim := false
		if payload.is_empty():
			dim = not bool(e.combinable)       # idle: cards that can't merge read as inert
		else:
			dim = i != src and not _can_pair(payload, i)
		item.modulate.a = 0.35 if dim else 1.0


# ── The merge framing ───────────────────────────────────────────────────────────

# Opens the in-place merge procedure: the grid dims down, and the TARGET card's spot grows the
# result — enlarged and radiant — wrapped by the framing (components left, full read right,
# Cancel + Combine/Attach beneath). Nothing is committed until the button.
func _open_merge(src: Dictionary, tgt_idx: int, verdict: Dictionary) -> void:
	if _modal != null:
		return
	_cancel_drag()
	# The SOURCE stays selected through the procedure — cancelling drops back to it, ready to
	# try another target. (Its highlight is suppressed while the modal is up; a COMMIT clears
	# the selection via _rebuild_deck.) A drag-initiated merge adopts its source the same way.
	_sel = src
	_merge = {"src": src, "tgt": tgt_idx, "verdict": verdict}

	# The dim backdrop — readability for the framing, and the tap-out-to-cancel surface. It also
	# hosts the fusion animation + result toast after the commit.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if _fusing:
			return
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close_modal())
	add_child(dim)
	_modal = dim
	_update_selection_highlights()   # modal up → highlight+tip suppressed (selection kept)
	_update_card_dimming()

	# Capture the anchor BEFORE any layout below: the framing centres on the target card's spot.
	var anchor := (_entries[tgt_idx].item as Control).get_global_rect().get_center()
	_build_cluster(src, tgt_idx, verdict)
	_place_cluster(anchor)


# Builds the framing cluster: [components] · [enlarged result] · [details], buttons beneath.
func _build_cluster(src: Dictionary, tgt_idx: int, verdict: Dictionary) -> void:
	var enchanting := str(src.get("kind", "")) == "charm"
	var result_inst: CardInstance = verdict.get("preview", null)

	# Sizes flow from the RESULT card: comfortably larger than a grid card, capped by the screen.
	var res_h := clampf(_card_size.y * 1.7, 300.0, size.y * 0.52)
	var res_w := res_h / CARD_ASPECT
	var plus_h := 42.0
	var comp_h := (res_h - plus_h) * 0.5
	var comp_w := comp_h / CARD_ASPECT

	var panel := PanelContainer.new()
	panel.mouse_filter = MOUSE_FILTER_STOP   # the framing swallows its own clicks — only the dim cancels
	var style := StyleBoxFlat.new()
	style.bg_color = Color(ScreenUI.SURFACE_DEEP, 0.97)
	style.set_border_width_all(2)
	style.border_color = ScreenUI.SURFACE_DEEP_BORDER
	style.set_corner_radius_all(14)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	_modal.add_child(panel)
	_cluster = panel

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	panel.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	col.add_child(row)

	# Components column: the two ingredients going in — stacked, joined by a "+".
	var comps := VBoxContainer.new()
	comps.alignment = BoxContainer.ALIGNMENT_CENTER
	comps.add_theme_constant_override("separation", 0)
	row.add_child(comps)
	_comp_holders = []
	var comp_size := Vector2(comp_w, comp_h)
	if enchanting:
		# Attach: the original card + the charm chip.
		comps.add_child(_make_component_card(_entries[tgt_idx].card.make_instance(), comp_size))
		var plus := _glyph("+", 32)
		plus.size_flags_horizontal = SIZE_SHRINK_CENTER
		comps.add_child(plus)
		comps.add_child(_make_component_charm(str(src.get("id", "")), comp_size))
	else:
		comps.add_child(_make_component_card(_entries[int(src.idx)].card.make_instance(), comp_size))
		var plus2 := _glyph("+", 32)
		plus2.size_flags_horizontal = SIZE_SHRINK_CENTER
		comps.add_child(plus2)
		comps.add_child(_make_component_card(_entries[tgt_idx].card.make_instance(), comp_size))

	row.add_child(_glyph("→", 44))

	# The star of the show: the target transformed into the result, enlarged and radiant.
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(res_w, res_h)
	holder.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(holder)
	_result_holder = holder
	if result_inst != null:
		var big := CardUI.create(result_inst)
		big.draggable = false
		big.custom_minimum_size = Vector2.ZERO
		big.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		# STOP (not IGNORE): the enlarged result behaves like any card — its standard hover
		# tooltip works, and right-click opens the full CardInspector.
		big.mouse_filter = MOUSE_FILTER_STOP
		holder.add_child(big)
		for cue: String in RESULT_READY_CUES:
			Vfx.attach(cue, holder)

	# Details column: verdict line (only when blocking) over THE standard card read —
	# CardTooltip.build_details, the exact composition every hover panel and the CardInspector
	# show (description, targeting policy, building note, abilities, charms, statuses). A
	# bespoke read here would drift the moment cards grow a new section; this one can't. It
	# sits on the tooltip's own dark surface — its palette is light-on-dark by design.
	var det_col := VBoxContainer.new()
	det_col.size_flags_vertical = SIZE_SHRINK_CENTER
	det_col.add_theme_constant_override("separation", 10)
	row.add_child(det_col)
	var det_s := 1.3
	var status := str(verdict.get("status", ""))
	if not status.is_empty():
		var st := Label.new()
		st.text = status
		st.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		st.custom_minimum_size.x = CardTooltip.COLUMN_WIDTH * det_s
		st.add_theme_font_size_override("font_size", 24)
		# Darkened, not lightened: the verdict must pop from the LIGHT framing surface.
		st.add_theme_color_override("font_color", (verdict.get("color", BAD_COLOR) as Color).darkened(0.35))
		det_col.add_child(st)
	if result_inst != null:
		var det_panel := PanelContainer.new()
		var det_style := StyleBoxFlat.new()
		det_style.bg_color = CardTooltip.BG_COLOR
		det_style.set_border_width_all(1)
		det_style.border_color = CardTooltip.BORDER_COLOR
		det_style.set_corner_radius_all(6)
		det_style.set_content_margin_all(12)
		det_panel.add_theme_stylebox_override("panel", det_style)
		det_panel.size_flags_vertical = SIZE_SHRINK_CENTER
		det_panel.add_child(CardTooltip.build_details(result_inst, det_s))
		det_col.add_child(det_panel)

	# The decision row: Cancel, then the big chunky commit button (with the Mineral cost on it).
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	col.add_child(buttons)
	var cancel := ScreenUI.action_button(Loc.t("common.cancel"), _close_modal,
		Vector2(200, 92), 26, ScreenUI.CHROME_NEUTRAL)
	buttons.add_child(cancel)
	var commit_text: String = Loc.t("combine.attach") if enchanting \
		else Loc.t("combine.combine_cost", {"n": int(verdict.get("cost", 0))})
	var commit := ScreenUI.action_button(commit_text, _commit_merge,
		Vector2(340, 92), 30, ScreenUI.CHROME_CONFIRM)
	commit.disabled = not bool(verdict.get("affordable", true))
	buttons.add_child(commit)
	_commit_btn = commit
	if not commit.disabled:
		for cue: String in COMBINE_READY_CUES:
			Vfx.attach(cue, commit)


# Positions the framing over the target card's grid spot (clamped fully on-screen) and pops it in.
func _place_cluster(global_anchor: Vector2) -> void:
	var panel := _cluster
	panel.modulate.a = 0.0
	await get_tree().process_frame   # the cluster needs a layout pass before its size is real
	if not is_instance_valid(panel) or _modal == null:
		return
	var local_anchor: Vector2 = _modal.get_global_transform().affine_inverse() * global_anchor
	var pos := local_anchor - panel.size * 0.5
	var margin := 12.0
	pos.x = clampf(pos.x, margin, maxf(_modal.size.x - panel.size.x - margin, margin))
	pos.y = clampf(pos.y, margin, maxf(_modal.size.y - panel.size.y - margin, margin))
	panel.position = pos
	panel.pivot_offset = panel.size * 0.5
	panel.scale = Vector2(0.92, 0.92)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, 0.14)
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "scale", Vector2.ONE, 0.18)


# A component mini-card for the framing's ingredients column.
func _make_component_card(inst: CardInstance, comp_size: Vector2) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = comp_size
	holder.size_flags_horizontal = SIZE_SHRINK_CENTER
	var ui := CardUI.create(inst)
	ui.draggable = false
	ui.custom_minimum_size = Vector2.ZERO
	ui.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	ui.mouse_filter = MOUSE_FILTER_PASS   # its standard hover tooltip still works in the framing
	holder.add_child(ui)
	_comp_holders.append(holder)
	return holder


# The charm chip as an Attach component, centred in a card-shaped cell so the column lines up.
func _make_component_charm(charm_id: String, comp_size: Vector2) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = comp_size
	holder.size_flags_horizontal = SIZE_SHRINK_CENTER
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var d := comp_size.x * 0.7
	cc.add_child(_make_charm_chip(charm_id, 1, Vector2(d, d)))
	holder.add_child(cc)
	_comp_holders.append(holder)
	return holder


# A "+" / "→" glyph for the framing, in the surface's ink so it reads on the light panel.
func _glyph(glyph: String, font_size: int) -> Label:
	var lbl := Label.new()
	lbl.text = glyph
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color("3a2f22", 0.75))
	lbl.size_flags_vertical = SIZE_SHRINK_CENTER
	return lbl


# Cancels the merge procedure back to the clean table. Safe to call anytime outside a fusion.
func _close_modal() -> void:
	if _fusing:
		return
	_drop_cluster()
	if _modal != null:
		_modal.queue_free()
		_modal = null
	_merge = {}
	_fuse_anim = null
	_update_selection_highlights()
	_update_card_dimming()


# Frees the framing cluster (detaching its sustained cues first) but keeps the dim backdrop —
# the commit paths reuse it for the fusion animation + result toast.
func _drop_cluster() -> void:
	if _result_holder != null:
		for cue: String in RESULT_READY_CUES:
			Vfx.detach(cue, _result_holder)
	if _commit_btn != null:
		for cue: String in COMBINE_READY_CUES:
			Vfx.detach(cue, _commit_btn)
	if _cluster != null:
		_cluster.queue_free()
		_cluster = null
	_comp_holders = []
	_result_holder = null
	_commit_btn = null


# The commit button: Attach spends the charm right away (then toasts the enchanted card);
# Combine plays the fusion sequence (the destructive deck mutation commits at its flash).
func _commit_merge() -> void:
	if _merge.is_empty() or _fusing:
		return
	var src: Dictionary = _merge.get("src", {})
	var tgt := int(_merge.get("tgt", -1))
	var verdict: Dictionary = _merge.get("verdict", {})
	if str(src.get("kind", "")) == "charm":
		var result_inst: CardInstance = verdict.get("preview", null)
		_do_enchant(str(src.get("id", "")), tgt)
		_drop_cluster()
		_show_result_toast(result_inst, Loc.t("combine.attached"))
		return
	if not bool(verdict.get("affordable", true)):
		return
	_start_fusion(int(src.get("idx", -1)), tgt, verdict.get("result_dc", null))


# ── Fusion (combine commit) ─────────────────────────────────────────────────────

# Flies clones of the two component cards from their framing spots into the result's spot,
# commits the merge at the flash, and reveals the result toast.
func _start_fusion(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	if _fusing or result_dc == null or _modal == null:
		return
	_fusing = true

	# Capture the fly-from/to geometry BEFORE the framing is dropped.
	var a_gc := (_comp_holders[0] as Control).get_global_rect().get_center()
	var b_gc := (_comp_holders[1] as Control).get_global_rect().get_center()
	var center := _result_holder.get_global_rect().get_center()
	var fly_size := (_comp_holders[0] as Control).size

	var a_inst := (_entries[src_idx].card as DeckCard).make_instance()
	var b_inst := (_entries[tgt_idx].card as DeckCard).make_instance()
	var result_inst := result_dc.make_instance()
	var color_a := _color_for_card(_entries[src_idx].data)
	var color_b := _color_for_card(_entries[tgt_idx].data)

	_drop_cluster()

	var anim := ForgeFuseAnim.new()
	anim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# At the flash: commit the merge (mutate deck + rebuild + combined SFX) — hidden behind the white.
	anim.flashed.connect(_on_fuse_flash.bind(src_idx, tgt_idx, result_dc))
	anim.finished.connect(_on_fuse_finished.bind(result_inst))
	_modal.add_child(anim)
	_fuse_anim = anim

	# The merge flash announces the newborn card's element: the combine element-variant bursts
	# at the collision point exactly when the white flash commits the merge. No variant live
	# (or placeholders muted) = the anim's own flash carries the moment, as before.
	var combine_vid := Vfx.resolve("combine", result_inst.data.elements)
	if not combine_vid.is_empty():
		var marker := Control.new()
		marker.mouse_filter = MOUSE_FILTER_IGNORE
		marker.size = Vector2(120, 120)
		_modal.add_child(marker)   # dies with the modal
		marker.global_position = center - marker.size * 0.5
		anim.flashed.connect(func() -> void: Vfx.play(combine_vid, marker))

	anim.play(a_inst, b_inst, result_inst, a_gc, b_gc, center, fly_size, color_a, color_b, OK_COLOR)


func _on_fuse_flash(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	_do_combine(src_idx, tgt_idx, result_dc)


func _on_fuse_finished(result_inst: CardInstance) -> void:
	_show_result_toast(result_inst, Loc.t("combine.forged"))


# The dismissible result toast: the new card centred over the dim with its name + description.
# Clicking the dim (outside the card) closes the whole modal; the card panel swallows its own
# clicks, so it's a true "click out to dismiss". The merge is already committed by this point.
func _show_result_toast(result_inst: CardInstance, title_text: String) -> void:
	if _modal == null or result_inst == null:
		return
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_modal.add_child(center)

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

	Vfx.play("ui_toast_glint", panel)   # the notice announces itself (carries its sound)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	var title := Label.new()
	title.text = title_text
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
	hint.text = Loc.t("combine.tap_continue")
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


# ── Apply ──────────────────────────────────────────────────────────────────────

func _do_combine(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> void:
	if result_dc == null or src_idx < 0:
		return
	# The mineral spend — recomputed here (the single commit point) so it can never drift from
	# what the preview quoted. Every route in already gated on affordability; the guard is
	# belt-and-braces against a stale UI.
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
	dc.add_charm(charm_id)
	GameData.current_run.charms.erase(charm_id)
	GameData.save_run()
	Sfx.combined()
	_rebuild_deck()
	_rebuild_charms()


# ── Particles ──────────────────────────────────────────────────────────────────

# Half-extents of the particle path. Start from the card's half-size, scale it by
# ForgeFX.AURA.radius_scale (the main handle — 1.0 = on the edge, >1 = wider, <1 = tighter), then
# add ForgeFX.AURA.margin for a flat px nudge on top. Tweak `radius_scale` to resize the ring.
func _card_aura_radii() -> Vector2:
	var fscale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	return Vector2(_card_size.x * 0.5 * fscale + margin, _card_size.y * 0.5 * fscale + margin)


func _aura_radii(payload: Dictionary) -> Vector2:
	if payload.kind == "card":
		return _card_aura_radii()
	var fscale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	var r := _charm_follower_size().x * 0.5   # match the charm follower
	return Vector2(r * fscale + margin, r * fscale + margin)


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
# a neutral blue. Shared by the drag source aura and the fusion clones.
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
