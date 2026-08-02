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

# Fallback card size (before the FitGrid's first layout lands) — see _live_card_size.
const CARD_SIZE := Vector2(160, 210)
# Native card aspect (260×340) — the merge framing sizes its result/component cards with it.
const CARD_ASPECT := 340.0 / 260.0
# All particle VFX tuning lives in ForgeFX (ForgeFX.AURA / ForgeFX.LINK).

const OK_COLOR   := Color(0.4, 1.0, 0.55)
const BAD_COLOR  := Color(1.0, 0.4, 0.4)

const DRAG_THRESHOLD := 12.0   # px the pointer must travel before a press becomes a drag (vs a tap)
# The merge framing's decision-row height — deliberately tall (the old 92 + 25%): the commit is
# the screen's one primary action while the framing is up, it should be hard to miss.
const MERGE_BTN_H := 115.0

# THE shared fit-all card grid (see FitGrid): sizes the whole deck to the table, centres the
# ragged last row (no remainder holes, ever), degrades to scrolling only at the touch floor.
var _fit_grid: FitGrid
var _scroll: ScrollContainer
var _charm_col: VBoxContainer
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
# Floating tip riding OUTSIDE the highlighted source (above it), tracked to it every frame in
# _process — it floats in the grid's own uniform gap above the card.
var _sel_tip: PanelContainer = null
var _sel_tip_label: Label = null
# The round purple ENGAGE buttons riding every VALID partner card's bottom edge while a source
# is selected — THE tap path into the merge (tapping a card's body always just selects it).
# Always visible, never hover-summoned: the player must see where they can go, not chase it.
# Icon-only (the selected card + tip already say what's happening); the full "Merge with X" /
# "Attach to X" line rides the tooltip. entry idx -> the fab Control. Fabs PERSIST across
# selection changes — only genuinely appearing/disappearing ones pop; tooltips refresh in
# place (per-fab "tip_sig" meta).
var _merge_btns: Dictionary = {}
# The engage button's diameter: a FAT fraction of the card it rides — it's the primary action
# on that card, it should read like one. Clamped for absurd card sizes.
const MERGE_BTN_RATIO := 0.522
const MERGE_BTN_MIN := 86.0
const MERGE_BTN_MAX := 158.0
# How much of the button hangs BELOW the card's bottom edge. Measured on the fab BOX, while the
# flask art rides lifted inside it (MERGE_FLASK_LIFT) — so the art's real protrusion is smaller
# than this number, and the two must be tuned together. It has to break the card's bottom border
# unmistakably (a button flush with the edge reads as card decoration, not as a control) without
# reaching into the row below in a tight spread.
const MERGE_BTN_OVERHANG := 0.28
# The fabs live on _overlay, a later sibling of the table — which is enough to draw above the
# cards RIGHT UP UNTIL one of them is picked: HighlightFx.set_grown lifts the selected card's
# z_index (Z_LIFT) inside this same canvas layer, and a z lift outranks tree order. The fab
# overhangs its host's bottom edge deliberately (see MERGE_BTN_OVERHANG / PREVIEW_DROP), so the
# grown source swallowed the flask of whatever card sat directly above it — the button vanished
# from exactly the card the player was reaching for. Overlay furniture therefore declares itself
# above any highlight lift, and the tip keeps its own rung above the fabs.
const MERGE_BTN_Z := HighlightFx.Z_LIFT + 5
const SEL_TIP_Z := MERGE_BTN_Z + 5
# THE Forge button — the same flask art the map's Forge fab shows. One button identity for
# "engage the forge", everywhere it appears.
const MERGE_FAB_TEX := preload("res://assets/buttons/forge.png")
# The engage fab's backplate: a fat yellow disc with a thick ink outline, sized SMALLER than the
# flask so the art overhangs it top and bottom and reads as floating ON the disc, not embedded in
# it. The disc — not the flask's ragged silhouette — is what makes the button look (and feel) like
# a target: the hit rect is the whole fab, and the plate is the shape that claims it.
# The disc is deliberately smaller than the flask's own extremes: the neck clears its top edge and
# the flared base's two corners cut CLEANLY past its bottom edge, with only the belly resting on
# open yellow. Both crossings have to be unambiguous breaks — a silhouette that merely grazes the
# outline reads as an awkward tangent, not as floating. Widening the disc until the base fits
# inside it is exactly the failure mode; the flask must always win at both ends.
const MERGE_PLATE_RATIO := 0.78          # disc diameter as a fraction of the fab box
const MERGE_FLASK_RATIO := 0.90          # flask art box, same fraction
const MERGE_FLASK_LIFT := 0.05           # how far the flask box rides above centre
const MERGE_PLATE_BORDER := 0.055        # outline thickness, also a fraction of the fab box
# The slim dense halo that lifts the flask off its own backplate (see the vfx entry). It is the
# button's LIT state and nothing else: a merge the player can't pay for drops the glow and dims to
# MERGE_BTN_UNLIT, so "which of these can I actually do right now" is answerable at a glance,
# without reading a cost or opening anything. The fab stays pressable — the framing is where the
# shortfall gets explained.
const MERGE_FLASK_GLOW := "forge_engage_flask_glow"
const MERGE_BTN_UNLIT := Color(0.62, 0.62, 0.68)

# Quick preview: entry idx -> the stand-in card overlay showing what that pairing would produce.
var _preview_uis: Dictionary = {}
# How far the stand-in is pushed DOWN over its host, as a fraction of the host card's height. The
# stand-in is otherwise the host's exact size — the offset is the whole composition. Sized to clear
# the TOP OF the card's name band — deliberately not the whole of it. The band's plaque runs from
# the card's top edge down to 12.5% of its height (NameBg's authored anchors shifted by its -12.5px
# offset at the 340px native height — card_ui.tscn), and this shows about two thirds of that: enough
# of the name to know which card is underneath, which is the entire job. Reading it letter by letter
# is not — a drop sized for the full band pushes the stand-in, and the merge fab riding its bottom
# edge, that much further down the table for nothing.
#
# Everything the stand-in hangs below its host is spent out of the table's row gap, and the fab's own
# overhang already spends nearly all of it, so the fab clips the top of the next row's name band by
# roughly this drop. Accepted deliberately: keeping it clear costs ~14% off every card on the screen
# (the gap would have to grow to a quarter of a card's height), and the fab is a round, floating
# thing that reads as chrome over the table rather than as part of the card it crosses.
const PREVIEW_DROP := 0.09
# The stand-in wears CardUI's shared phantom treatment (CardUI.set_phantom) — the one "this card
# isn't real" look, so a stand-in on the table and the same card enlarged in the inspector can
# never drift apart.
# Soft purple, NOT the warm yellow this started as: the deck is full of orange/gold fire art and a
# yellow disc dissolved into those backgrounds. Purple is the one hue no card art leans on, so the
# button separates from every element's palette — and it echoes the screen's own lavender chrome.
const MERGE_PLATE_FILL := Color(0.68, 0.56, 0.90)
const MERGE_PLATE_EDGE := Color(0.16, 0.13, 0.09)

# The open merge procedure ({} = closed): {"src": payload, "tgt": entry idx, "verdict": Dictionary}.
var _merge: Dictionary = {}
# The merge modal rides its OWN CanvasLayer, ABOVE the table's Vfx overlay band — so the
# selected card's highlight stays attached through the merge (dimmed under the scrim with the
# rest of the table), while effects on modal widgets land in the modal's band above the scrim
# (see Vfx.overlay_layer_for).
const MODAL_LAYER := 100
var _modal_layer: CanvasLayer = null
var _modal: Control = null          # the dim backdrop — also hosts the fusion anim + result toast
# A press that closed the modal must consume its own RELEASE too — otherwise the release
# arrives with the modal already gone and reads as a dead-space click (which deselects).
var _swallow_release := false
var _cluster: Control = null        # the framing cluster (freed on commit, before the fusion)
var _comp_holders: Array = []       # the two component visuals — the fusion's fly-from points
var _result_holder: Control = null  # the enlarged result card's holder (wears the radiance cues)
var _commit_btn: Button = null
# Fusion-animation state, live only between hitting Combine and dismissing the result toast. While
# _fusing is true the modal dim ignores clicks/Esc so the sequence can't be cut off mid-flight.
var _fusing := false
# Whether the fusion in flight is a QUICK merge (no scrim, no framing, no result toast) — it ends
# by tearing itself down instead of handing off to the toast.
var _quick_fusing := false
var _fuse_anim: ForgeFuseAnim = null
# The forged DeckCard whose grid shell is still hidden under its flying clone. Cleared at
# touchdown; _close_modal uses it to rescue the shell if the player dismisses the toast while
# the return flight is still in the air (the anim dies with the modal, so touchdown never comes
# — without this the forged card would stay invisible forever).
var _pending_land: DeckCard = null

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
	# The Forge owns the contact-splash look: the renderer behind the `forge_contact_splash`
	# library entry (re-registering on every screen entry overwrites — the convention, see
	# Vfx.register_custom).
	Vfx.register_custom("forge_contact_splash", ForgeSplash.play_entry)
	_build_ui()
	_rebuild_deck()
	_rebuild_charms()


func get_chrome() -> Dictionary:
	# Standard chrome: the header carries the Mineral chip (the only run stat that matters here)
	# and the ✕; the footer carries Back. The OS back gesture / Esc first cancels an open merge.
	# inset: false — the table is full-bleed art (like the map); the Shell's shared menu margins
	# would compress it into a floating panel. Header/footer stay as their own rows regardless.
	return {"title": Loc.t("combine.title"), "fields": [ScreenUI.Field.MINERAL],
		"exit": _leave, "back": _back_or_cancel, "show_footer": true, "inset": false,
		"aid": Loc.t("combine.aid_idle"),
		"header_actions": [{
			"label": Loc.t("combine.quick_preview"), "tip": Loc.t("combine.quick_preview_tip"),
			"toggle": true, "pressed": _quick_preview(), "action": _on_quick_preview_toggled,
		}, {
			"label": Loc.t("combine.quick_merge"), "tip": Loc.t("combine.quick_merge_tip"),
			"toggle": true, "pressed": _quick_merge(), "action": _on_quick_merge_toggled,
		}]}


# Whether merges commit on the spot, with no confirmation framing (profile-scoped, persisted).
# Read through here rather than off the profile directly: with no profile loaded (the render
# harness, a headless test) the answer is the safe one — ask first.
func _quick_merge() -> bool:
	var p := GameData.current_profile
	return p != null and p.quick_merge


# The header toggle. Turning it ON the first time has to survive a warning first — a merge is
# destructive and irreversible, and this switch removes the only step that was standing between a
# mis-tap and a spent card. The warning is a one-time ritual (quick_merge_ack): once the player has
# read it, re-toggling is just a setting, and re-asking every time would train them to dismiss it.
# Declining snaps the button back off — the profile, not the button, is the source of truth here,
# and _present reconciles the chrome from it.
func _on_quick_merge_toggled(on: bool) -> void:
	var p := GameData.current_profile
	if p == null:
		return
	if on and not p.quick_merge_ack:
		ConfirmOverlay.ask(self, Loc.t("combine.quick_merge_title"),
			Loc.t("combine.quick_merge_warning"),
			func() -> void:
				p.quick_merge_ack = true
				_set_quick_merge(true),
			Loc.t("combine.quick_merge_enable")
		).closed.connect(func(confirmed: bool) -> void:
			if not confirmed:
				_refresh_chrome())   # declined: put the button back where the profile says
		return
	_set_quick_merge(on)


# Whether valid partners show what they WOULD become while a source is picked (profile-scoped,
# persisted). Same safe default as _quick_merge with no profile: off.
func _quick_preview() -> bool:
	var p := GameData.current_profile
	return p != null and p.quick_preview


# No confirmation ritual here, unlike quick merge: this only changes how the table LOOKS, and a
# warning on a reversible view setting would be crying wolf.
func _on_quick_preview_toggled(on: bool) -> void:
	var p := GameData.current_profile
	if p == null or p.quick_preview == on:
		return
	p.quick_preview = on
	GameData.save_profile()


func _set_quick_merge(on: bool) -> void:
	var p := GameData.current_profile
	if p == null or p.quick_merge == on:
		return
	p.quick_merge = on
	GameData.save_profile()


# Re-reads this screen's chrome declaration into the persistent header — the way to push a change
# that the header shows (the quick-merge toggle's state) without touching the header directly.
func _refresh_chrome() -> void:
	Nav.refresh_chrome()


# OS back / Esc peels state before it ever leaves the room: an open merge closes first, then a
# live selection clears, and only a clean table navigates away.
func _back_or_cancel() -> void:
	if _modal != null:
		if not _fusing:
			_close_modal()
		return
	if not _sel.is_empty():
		_sel = {}
		return
	_leave()


func _exit_tree() -> void:
	# The mixing loop lives on the Sfx AUTOLOAD, so it survives this screen being freed — leaving
	# mid-drag (Shell frees content on navigation, no _cancel_drag runs) would otherwise let the
	# drone play forever over the next screen.
	Sfx.mixing_stop()


func _build_ui() -> void:
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

	# The card table — the whole deck on the SHARED fit-all grid (FitGrid, same as Decks/events/
	# King picks): largest cards that all fit, centred ragged last row (no remainder holes,
	# ever), degrades to scrolling only at the touch floor.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	body.add_child(scroll)
	_scroll = scroll

	# FitGrid fills the WHOLE scroll area (no reserved tip lanes — those added a top/bottom-only
	# inset that broke the uniform border: the vertical card-to-edge gap then didn't match the
	# between-row gap). The selection pills float in the grid's own uniform gap instead.
	_fit_grid = FitGrid.new()
	_fit_grid.uniform_gap = true        # card gaps == border gaps, per axis (see FitGrid)
	_fit_grid.separation = 28.0         # the minimum gap everywhere — a touch of breathing room
	_fit_grid.min_card_width = 150.0    # the touch floor — absurd decks degrade to scrolling
	_fit_grid.animate = true            # reflows glide (survivors persist — see _rebuild_deck)
	_fit_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_fit_grid.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.add_child(_fit_grid)

	# Drag overlay: floats above everything, never eats input.
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_overlay)

	# The selection tip: a dark pill floating just above the highlighted source card/chip, in the
	# grid's uniform top gap (clamped on-screen by _track_sel_tip).
	_sel_tip = _make_tip_pill(22, Color(0.98, 0.97, 0.92), 0.66)
	_sel_tip_label = _sel_tip.get_child(0) as Label
	_sel_tip.z_index = SEL_TIP_Z   # the instruction always reads OVER the engage fabs it may overlap
	_overlay.add_child(_sel_tip)


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

# The live fitted card size (FitGrid drives every item's rect) — for the drag follower and the
# aura radii. Falls back to CARD_SIZE before the first layout lands.
func _live_card_size() -> Vector2:
	if not _entries.is_empty():
		var it: Control = _entries[0].item
		if is_instance_valid(it) and it.size.x > 0.0:
			return it.size
	return CARD_SIZE


# A RECONCILE, not a teardown: entries whose DeckCard survives keep their live nodes (only their
# indices refresh), so the FitGrid's animated reflow has persistent widgets to glide — a full
# rebuild would hand it a table of strangers and every combine would snap. Only genuinely
# removed cards free, only genuinely new ones are built. `changed` lists surviving DeckCards
# whose FACE went stale (a combine rewrote the target's definition, an enchant added a charm
# pip) — those keep their SHELL (the ForgeDragItem node, so the grid still sees a survivor) and
# swap only the inner CardUI. The highlight needs no manual reset: _present reconciles the
# wearer from _sel, whether the old wearer survived or is being freed.
func _rebuild_deck(changed: Array = []) -> void:
	_cancel_drag()
	_clear_previews()
	_sel = {}

	var reuse: Dictionary = {}   # DeckCard -> its live entry (survivors keep identity across deck edits)
	for e: Dictionary in _entries:
		reuse[e.card] = e
	_entries.clear()

	var items: Array = []
	var deck: Array = GameData.current_run.deck.duplicate()
	for i in deck.size():
		var dc: DeckCard = deck[i]
		var prev: Dictionary = reuse.get(dc, {})
		if not prev.is_empty():
			var shell := prev.item as ForgeDragItem
			if changed.has(dc) and not _refresh_face(prev):
				shell.queue_free()   # the card's new definition doesn't resolve — drop the entry
				continue
			shell.payload = {"kind": "card", "idx": _entries.size()}
			prev.deck_idx = i
			_entries.append(prev)
			items.append(shell)
			continue

		var data := CardData.get_card(dc.id)
		if data == null:
			continue
		var ui := CardUI.create(dc.make_instance())
		ui.draggable = false   # the Forge drives its own drag; CardUI's combat drag stays off

		var combinable := data.elements.size() > 0 or data.chess_pieces.size() > 0

		# Every card is wrapped so it can be a drop TARGET (rect hit-test) and receive taps (a
		# charm's enchant target); only combinable cards can SOURCE a merge (drag or first tap).
		var item := ForgeDragItem.new()
		item.setup(ui, {"kind": "card", "idx": _entries.size()})
		# Hover detail comes from the CardUI's OWN standard tooltip (ForgeDragItem leaves the card on
		# MOUSE_FILTER_PASS) — the same path the rest of the game uses; nothing bespoke here.
		item.grab.connect(_on_press)

		_entries.append({ "card": dc, "deck_idx": i, "data": data, "ui": ui, "item": item,
			"combinable": combinable })
		items.append(item)

	_fit_grid.set_cards(items)   # diff-aware: keeps survivors, frees the gone, glides the reflow
	_present()


# Rebuilds an entry's FACE (the inner CardUI) in place, keeping its SHELL — the ForgeDragItem
# the grid lays out — untouched. For any surviving DeckCard whose definition went stale (a
# combine rewrote it, an enchant added a charm). Building a CardUI is heavyweight (art, badges,
# chips), so callers time this for a quiet frame — never one where an animation is launching.
# Returns false if the new definition doesn't resolve.
func _refresh_face(e: Dictionary) -> bool:
	var dc: DeckCard = e.card
	var data := CardData.get_card(dc.id)
	if data == null:
		return false
	(e.ui as Control).queue_free()
	var ui := CardUI.create(dc.make_instance())
	ui.draggable = false
	var shell := e.item as ForgeDragItem
	shell.setup(ui, shell.payload)
	e.data = data
	e.ui = ui
	e.combinable = data.elements.size() > 0 or data.chess_pieces.size() > 0
	return true


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
	# The charm's own face — art when it has any (see CharmData.badge). The rail used to draw a
	# coloured disc with the charm's letter and never look at the asset, so every painted charm
	# showed as a placeholder here and in the drag follower this chip feeds.
	var charm := CharmData.get_charm(charm_id)
	if charm == null:
		var missing: Panel = TextIcons.TipPanel.new()
		missing.custom_minimum_size = size
		var ms := StyleBoxFlat.new()
		ms.bg_color = Color(0.4, 0.4, 0.5)
		ms.set_corner_radius_all(int(size.x * 0.5))
		ms.set_border_width_all(2)
		ms.border_color = Color(0.04, 0.04, 0.06, 0.9)
		missing.add_theme_stylebox_override("panel", ms)
		return missing
	var chip := charm.badge(size.x, count)
	chip.custom_minimum_size = size
	UIScale.tip(chip, "%s — %s" % [charm.display_name, charm.description])
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

	# Dragging IS selecting: the lifted card/charm becomes the declared source, and stays
	# selected after the drop wherever it lands (the merge adopts it; a drop on nothing keeps
	# it). _present derives the rest (tip hidden mid-drag, dimming from this payload).
	_sel = payload.duplicate()

	# The dragged source's spot reads EMPTY: the card is fully hidden (alpha 0) but its item
	# keeps its layout slot, so the grid never reflows mid-drag and no card slides under the
	# pointer. The follower in the overlay IS the card while the gesture lasts; everything
	# snaps back to normal (visible + highlighted-as-selected) when the drag ends.
	if payload.kind == "card":
		_entries[payload.idx].item.modulate.a = 0.0

	_update_drag(get_global_mouse_position())


func _make_follower_visual(payload: Dictionary) -> Control:
	if payload.kind == "card":
		var inst: CardInstance = _entries[payload.idx].card.make_instance()
		var ui := CardUI.create(inst)
		ui.custom_minimum_size = _live_card_size()
		ui.size = _live_card_size()
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


# Keeps the floating tip glued to the highlighted source — the source moves under it (scroll,
# refit, the highlight's own grow animation), so it follows every frame it's shown. It prefers the
# grid's uniform top gap, and FLIPS below the card when that gap isn't there.
#
# The flip is the whole point: a top-row card has no room above it, and clamping the tip down to
# the overlay's top edge parked it ON the card — where the selection Highlight (which rides the
# overlay layer, above this one) drew straight over it. Clamping a floating label into the thing
# it describes is never the right answer; move it to the side that has room.
const SEL_TIP_GAP := 10.0

func _track_sel_tip() -> void:
	if _sel_tip == null or not _sel_tip.visible or _hl_item == null or not is_instance_valid(_hl_item):
		return
	var r := _hl_item.get_global_rect()   # transform-aware: tracks the grown (scaled) card
	var ov := _overlay.get_global_rect()
	var sz := _sel_tip.size
	var above := r.position.y - sz.y - SEL_TIP_GAP
	var pos := Vector2(r.get_center().x - sz.x * 0.5, above)
	if above < ov.position.y + 6.0:
		pos.y = r.end.y + SEL_TIP_GAP      # no gap above — hang it under the card instead
	pos.x = clampf(pos.x, 6.0, ov.end.x - sz.x - 6.0)
	# Horizontal clamping can't push the tip onto the card, so it stays a plain clamp; the vertical
	# one is only the last-resort guard for a source taller than the whole overlay.
	pos.y = clampf(pos.y, ov.position.y + 6.0, maxf(ov.position.y + 6.0, ov.end.y - sz.y - 6.0))
	_sel_tip.global_position = pos


# Per-frame: reconcile the presentation from the declared state, then drive the dragged card's
# wobble (easing in while a link is active, out when it breaks).
func _process(delta: float) -> void:
	_present()
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
		# A press that closed the modal (see _open_merge's dim handler) already did its work —
		# its release must not be re-read as a dead-space click. One physical click, one meaning.
		if not mb.pressed and _swallow_release:
			_swallow_release = false
			return
		var on_preview := _preview_under(get_global_mouse_position()) \
				if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed else -1
		# NEVER on our own floating buttons, for the same reason the dead-space branch below spells
		# out: _input runs BEFORE the GUI, and the fab rides the stand-in it belongs to (72% of it
		# sits inside that rect). Forwarding a press aimed at the flask made the release resolve as a
		# TAP on the target first, moving the selection onto it — so by the time the fab's `pressed`
		# fired, the source and the target were the same card and the merge was of a card with itself.
		if on_preview >= 0 and not _click_on_ui(get_global_mouse_position()):
			# A press that lands on a stand-in belongs to the card underneath — it selects and drags
			# exactly as pressing the card itself does. It has to be started HERE because the grid's
			# press comes from ForgeDragItem._gui_input, and the stand-in does not live inside that
			# wrapper (it rides the screen overlay, to escape the scroll clip) — so the GUI walks the
			# stand-in's own ancestors and never reaches the item. _on_press is self-guarded against
			# a double start, so the strip of host card still showing above the stand-in, which DOES
			# reach the wrapper, stays exactly as it was.
			_on_press({"kind": "card", "idx": on_preview})
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
			elif not _sel.is_empty() and not _click_on_ui(get_global_mouse_position()):
				# A click that never grabbed a card or charm — empty table, rail, any dead space —
				# is the ONE deselecting act (besides tapping the source again). NEVER on our own
				# floating buttons: _input runs BEFORE the GUI, so clearing here would gut the
				# selection an instant before the button's pressed (fires on release) reads it.
				_sel = {}
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if not _drag.is_empty():
				_cancel_drag()   # right-click aborts the drag without merging
				get_viewport().set_input_as_handled()
			elif not _pending.is_empty():
				_pending = {}
			elif not _sel.is_empty() and _target_under(get_global_mouse_position()) < 0 \
					and not _click_on_ui(get_global_mouse_position()):
				# Right-click on dead space drops the selection. ON a card the event falls
				# through untouched to the GUI, where CardUI opens the full CardInspector —
				# right-click = card details, the same language as everywhere else.
				_sel = {}
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
#
# A card's reach includes any quick-preview stand-in it is wearing. The stand-in is dropped below
# its host, so its bottom strip hangs past the host's own rect, over the row gap — and that strip is
# unmistakably part of the card you are pointing at. Without this it read as dead space: a press
# there dropped the selection instead of pairing, and a right-click was eaten before the GUI could
# turn it into an inspect.
func _target_under(global_pos: Vector2) -> int:
	# Stand-ins are tested FIRST because they are drawn on top: where one overhangs into the row
	# below, the card you are pointing at is the one you can see, not the one buried under it.
	var pi := _preview_under(global_pos)
	if pi >= 0 and not (_drag.get("kind") == "card" and int(_drag.get("idx", -1)) == pi):
		return pi
	for i in _entries.size():
		if _drag.get("kind") == "card" and int(_drag.get("idx", -1)) == i:
			continue
		var item: Control = _entries[i].item
		if item != null and item.get_global_rect().has_point(global_pos):
			return i
	return -1


# The entry whose quick-preview stand-in covers `global_pos`; -1 if none. The stand-in's whole rect
# belongs to its host card — including the strip that hangs past the host, over the row gap.
func _preview_under(global_pos: Vector2) -> int:
	for i: int in _preview_uis:
		var pv: Variant = _preview_uis[i]
		if is_instance_valid(pv) and (pv as Control).visible \
				and (pv as Control).get_global_rect().has_point(global_pos):
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
	# Where the player actually LET GO, captured before _cancel_drag frees the follower. A quick
	# merge fuses straight out of this point, so the card carries on from under the thumb instead
	# of snapping back to its grid slot to start the flight from there.
	var origin := Vector2.INF
	if _follower != null and is_instance_valid(_follower):
		origin = _follower.global_position + _follower_center
	_cancel_drag()
	if hover >= 0 and bool(verdict.get("ok", false)):
		_open_merge(payload, hover, verdict, origin)


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
		# One charm per component: a card that has filled its slots says so, and says how to earn
		# more — merging is what widens a composition (see DeckCard.charm_capacity).
		if (tgt.card as DeckCard).charm_room() <= 0:
			return {"ok": false, "status": Loc.t("combine.status_charms_full",
				{"card": data.display_name, "max": (tgt.card as DeckCard).charm_capacity()}),
				"color": BAD_COLOR}
		var preview_dc := (tgt.card as DeckCard).clone()
		preview_dc.add_charm(str(payload.id))
		return {"ok": true, "status": "", "color": OK_COLOR, "preview": preview_dc.make_instance()}


# Union of both parents' charms still valid on the combined result, capped at what the result can
# bear. The arithmetic says a merge can't overflow — the result's components are the sum of its
# parents', and each parent was itself within capacity — but a card charmed before the capacity
# rule existed can carry more than it should, and inheritance must not launder that into the new
# card. Parent order wins the tie, so the first-picked card's enchantments carry over first.
func _merged_parent_charms(parents: Array, result_card: CardData) -> Array:
	var out: Array = []
	var room := result_card.component_count()
	for dc: DeckCard in parents:
		for charm_id: String in dc.charms:
			if out.size() >= room:
				return out
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
	# Capacity grays a full card exactly as "already wearing this one" does — both are structural
	# facts about the pairing, which is what this gate is for.
	return charm.can_attach_to(data) and DeckCard.can_bear_charm_on(
		data, (_entries[idx].card as DeckCard).charms, str(payload.get("id", "")))


# ── Selection (tap flow) ────────────────────────────────────────────────────────

# A press on a deck card / charm: held as pending until release (tap) or movement (drag).
func _on_press(payload: Dictionary) -> void:
	# The grid mid-reflow is briefly non-interactive: a press would aim at cards whose rects are
	# in flight. The settle is fast (FitGrid.ANIM_T) — the press simply doesn't land.
	if _modal != null or not _drag.is_empty() or not _pending.is_empty() \
			or _fit_grid.is_settling():
		return
	_pending = payload
	_press_pos = get_global_mouse_position()


# A tap (press+release without dragging). Tapping ALWAYS selects — a card's body never opens
# the merge (browsing must be friction-free; a stale selection must never hijack a click). The
# merge lives on the per-target "Merge with X" buttons and the drag. Pure state mutation —
# _present derives all the visuals.
func _on_tap(payload: Dictionary) -> void:
	if payload.get("kind") == "charm":
		var cid := str(payload.get("id", ""))
		if _sel.get("kind", "") == "charm" and str(_sel.get("id", "")) == cid:
			_sel = {}                          # tapping the selected charm again deselects it
		else:
			_sel = {"kind": "charm", "id": cid}
		return

	var idx := int(payload.idx)
	if _sel.get("kind", "") == "card" and int(_sel.get("idx", -1)) == idx:
		_sel = {}                              # tapping the source again deselects it
	elif bool(_entries[idx].combinable):       # non-combinable cards can't source a merge
		_sel = {"kind": "card", "idx": idx}


# THE sole presenter: derives every visual consequence of the declared state (_sel, _drag,
# _modal) — who wears the canonical Highlight, the floating tips, the pairability dimming.
# Polled from _process (idempotent, cheap): transitions just MUTATE STATE and the presentation
# self-heals next frame, so no path can forget a visual pairing — the class of bug the old
# per-transition attach/detach bookkeeping kept producing. The selected source keeps its
# highlight through an open merge: the modal scrim rides a HIGHER CanvasLayer (MODAL_LAYER)
# than the table's effect band, so the whole table — card and highlight alike — dims under it.
func _present() -> void:
	if _hl_item != null and not is_instance_valid(_hl_item):
		_hl_item = null   # its wearer was freed (deck rebuild) — the attach auto-detached
	var want: Control = null
	# Mid-drag, NOTHING wears the highlight: the dragged source's spot reads empty (the
	# follower is the card now), and outlining a hidden widget would bake a ghost silhouette.
	# The selection itself persists — the highlight returns the frame the drag ends.
	if _drag.is_empty():
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
		# Both halves of the treatment, together: the overlay outline+glow, and the grow, which is
		# the WIDGET's own state (HighlightFx.set_grown) rather than the effect's — see the note
		# there. Only ever called when which item is picked actually changes.
		if _hl_item != null:
			Vfx.detach("highlight", _hl_item)
			HighlightFx.set_grown(_hl_item, false)
		_hl_item = want
		if want != null:
			Vfx.attach("highlight", want)
			HighlightFx.set_grown(want, true)
	# The floating tip rides with the highlight — hidden mid-drag (the drag IS the affordance)
	# and under an open merge (the framing carries the read there).
	var show_tip := want != null and _drag.is_empty() and _modal == null
	_sel_tip.visible = show_tip
	if show_tip:
		if _sel.get("kind", "") == "charm":
			var charm := CharmData.get_charm(str(_sel.get("id", "")))
			_sel_tip_label.text = Loc.t("combine.tap_to_enchant",
					{"charm": charm.display_name if charm != null else ""})
		else:
			_sel_tip_label.text = Loc.t("combine.pick_target")
		_track_sel_tip()
	# Previews FIRST: a card wearing a stand-in hands its merge fab a different rect to ride (the
	# stand-in's, not its own), so the fabs must reconcile against stand-ins that already exist.
	_reconcile_previews()
	_reconcile_merge_buttons()
	_update_card_dimming()
	Nav.set_aid(_aid_text())


# The footer's guidance line, derived from the same declared state as everything else here — it
# walks the merge one step at a time rather than describing the whole screen at once: what to pick
# while nothing is picked, then how to land it once something is. Mid-drag it goes quiet: the card
# under the thumb and the lit flasks ARE the instruction at that point, and a line of text
# competing with them is noise.
func _aid_text() -> String:
	if _modal != null or not _drag.is_empty():
		return ""
	if _sel.get("kind", "") == "charm":
		return Loc.t("combine.aid_charm_picked")
	if _sel.get("kind", "") == "card":
		return Loc.t("combine.aid_picked")
	return Loc.t("combine.aid_idle")


# The round engage buttons on valid partner cards — THE tap path into the merge (a tap on a
# card's body always just selects). One on EVERY valid partner whenever a source is selected:
# always on, never hover-summoned. Reconciled every frame like the rest of the presentation.
# A fab that stays valid across a selection change NEVER re-animates — only genuine appear/
# disappear transitions pop.
func _reconcile_merge_buttons() -> void:
	var want: Dictionary = {}
	if not _sel.is_empty() and _modal == null and _drag.is_empty():
		var src_idx := int(_sel.get("idx", -1)) if _sel.get("kind", "") == "card" else -1
		for i in _entries.size():
			if i != src_idx and _can_pair(_sel, i):
				want[i] = true

	for i: int in _merge_btns.keys():
		if not want.has(i):
			_pop_out_btn(_merge_btns[i])
			_merge_btns.erase(i)
	var tip_key := "combine.attach_to" if _sel.get("kind", "") == "charm" else "combine.merge_with"
	for i: int in want:
		var fresh := not _merge_btns.has(i)
		if fresh:
			_merge_btns[i] = _make_merge_button(i)
		var fab: Control = _merge_btns[i]
		# Riding the card's bottom edge, centred — mostly INSIDE the card, only
		# MERGE_BTN_OVERHANG of it hanging below: unmissable without eating the table's gaps.
		# When the card wears a quick-preview stand-in, the fab rides the STAND-IN's bottom edge
		# instead: that is the card the player is being asked to commit to, and measuring against
		# the host would leave the fab stranded across the middle of the stand-in's art. Same size
		# either way (the stand-in is the host's size), so ONLY which rect is measured changes — the
		# fab keeps its authored relationship to a card exactly, overhang included.
		var r := (_entries[i].item as Control).get_global_rect()
		var pv: Variant = _preview_uis.get(i)
		if is_instance_valid(pv) and (pv as Control).visible:
			r = (pv as Control).get_global_rect()
		var d := clampf(r.size.x * MERGE_BTN_RATIO, MERGE_BTN_MIN, MERGE_BTN_MAX)
		fab.size = Vector2(d, d)
		# Raw `position`, NOT global_position: the global setter compensates for the pivot-scale
		# transform, which would pin the VISUAL top-left corner mid-pop — the "expanding from a
		# corner" artifact. The layout position is scale-independent, so the pivot-centred pop
		# breathes in place.
		fab.position = Vector2(r.get_center().x - d * 0.5,
				r.end.y - d * (1.0 - MERGE_BTN_OVERHANG)) - _overlay.global_position
		fab.pivot_offset = fab.size * 0.5   # scale pops grow from the button's centre
		# Affordability is a per-TARGET fact (cost scales with what the two cards are), so it's
		# reconciled here alongside the placement rather than once per selection. Riding `fab`'s
		# modulate leaves `face`'s free for the hover/press feedback — the two compose instead of
		# overwriting each other.
		_set_fab_lit(fab, _affordable_with(_sel, i))
		# Tooltip tracks the live pairing (kind + target name) without rebuilding the fab.
		var tip_sig := tip_key + "|" + (_entries[i].data as CardData).display_name
		if fresh or str(fab.get_meta("tip_sig", "")) != tip_sig:
			fab.set_meta("tip_sig", tip_sig)
			UIScale.tip(fab.get_meta("btn") as Control,
					Loc.t(tip_key, {"name": (_entries[i].data as CardData).display_name}))
		if fresh:
			fab.scale = Vector2(0.15, 0.15)
			var tw := fab.create_tween()
			tw.tween_property(fab, "scale", Vector2.ONE, 0.22) \
					.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Whether the run can currently PAY for pairing `payload` with the card at `idx`. Structure is
# _can_pair's job; this is only about the Mineral. A charm attach costs nothing, so it is always
# affordable — the fab lights for every valid target.
func _affordable_with(payload: Dictionary, idx: int) -> bool:
	if payload.get("kind", "") != "card":
		return true
	var src := int(payload.get("idx", -1))
	if src < 0 or src >= _entries.size() or idx < 0 or idx >= _entries.size():
		return true
	var cost := ForgeCosts.merge_cost(_entries[src].data as CardData, _entries[idx].data as CardData)
	var have: int = GameData.current_run.magic_mineral if GameData.current_run != null else 0
	return have >= cost


# The fab's lit/unlit state: the flask's halo and its full colour together. Idempotent and cheap —
# it's polled every frame with the rest of the presentation, so it only touches Vfx on an actual
# transition (attach/detach are not free, and re-attaching per frame would rebake the silhouette).
func _set_fab_lit(fab: Control, lit: bool) -> void:
	if bool(fab.get_meta("lit", true)) == lit:
		return
	fab.set_meta("lit", lit)
	fab.modulate = Color.WHITE if lit else MERGE_BTN_UNLIT
	var tex: Control = fab.get_meta("tex")
	if lit:
		Vfx.attach(MERGE_FLASK_GLOW, tex)
	else:
		Vfx.detach(MERGE_FLASK_GLOW, tex)


# Shrinks a retiring engage fab to nothing, then frees it — the counterpart of the pop-in.
# Mid-pop clicks are harmless: _on_merge_btn re-validates against the live state.
func _pop_out_btn(b: Variant) -> void:
	if not is_instance_valid(b):
		return
	var c := b as Control
	var tw := c.create_tween()
	tw.tween_property(c, "scale", Vector2.ZERO, 0.12) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(c.queue_free)


# The engage affordance IS the map's Forge flask, small — mounted on its own round backplate (the
# map's fab stands alone on the map art and keeps the bare flask; here it sits in a dense card
# spread and needs a shape that claims its space). Plate + flask are a single `face` Control so
# the hover-brighten / press-sink feedback modulates both as one object, with a transparent Button
# over the whole fab for the click and tooltip. The "Merge with X"/"Attach to X" line rides the
# tooltip.
func _make_merge_button(idx: int) -> Control:
	var fab := Control.new()   # sized per-card by the reconcile
	# Only the round Button may take a click here — a STOP-filtered wrapper would silently claim
	# the box corners the button itself declines.
	fab.mouse_filter = MOUSE_FILTER_IGNORE
	fab.z_index = MERGE_BTN_Z   # above any highlighted card's z lift — see MERGE_BTN_Z

	var face := Control.new()  # plate + flask, modulated together by the button feedback
	face.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	face.mouse_filter = MOUSE_FILTER_IGNORE
	fab.add_child(face)

	# Anchored (not sized) so it re-centres itself for free whenever the reconcile resizes the fab
	# to the card it rides. A huge corner radius is clamped to half the box by StyleBoxFlat, so the
	# square panel draws as a true circle at ANY diameter — no per-size radius bookkeeping.
	var plate := Panel.new()
	var m := (1.0 - MERGE_PLATE_RATIO) * 0.5
	plate.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	plate.anchor_left = m
	plate.anchor_top = m
	plate.anchor_right = 1.0 - m
	plate.anchor_bottom = 1.0 - m
	plate.mouse_filter = MOUSE_FILTER_IGNORE
	face.add_child(plate)

	var tex := TextureRect.new()
	tex.texture = MERGE_FAB_TEX
	var fm := (1.0 - MERGE_FLASK_RATIO) * 0.5
	tex.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	tex.anchor_left = fm
	tex.anchor_top = fm - MERGE_FLASK_LIFT
	tex.anchor_right = 1.0 - fm
	tex.anchor_bottom = 1.0 - fm - MERGE_FLASK_LIFT
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = MOUSE_FILTER_IGNORE
	face.add_child(tex)

	# The outline is the one part that can't be anchored — it's a pixel width. Re-derived from the
	# live box on every resize so a fab on a big card doesn't wear a hairline.
	var restyle := func() -> void:
		var ps := StyleBoxFlat.new()
		ps.bg_color = MERGE_PLATE_FILL
		ps.border_color = MERGE_PLATE_EDGE
		ps.set_border_width_all(maxi(2, int(round(fab.size.x * MERGE_PLATE_BORDER))))
		ps.set_corner_radius_all(4096)
		plate.add_theme_stylebox_override("panel", ps)
	restyle.call()
	fab.resized.connect(restyle)

	var btn := RoundButton.new()
	btn.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	btn.focus_mode = Control.FOCUS_NONE
	for s: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	fab.set_meta("btn", btn)   # the reconcile owns the tooltip (it tracks the live pairing)
	btn.pressed.connect(_on_merge_btn.bind(idx))
	btn.mouse_entered.connect(func() -> void:
		if not btn.button_pressed:
			face.modulate = Color(1.12, 1.12, 1.12))
	btn.mouse_exited.connect(func() -> void: face.modulate = Color.WHITE)
	btn.button_down.connect(func() -> void: face.modulate = Color(0.85, 0.85, 0.85))
	btn.button_up.connect(func() -> void: face.modulate = Color.WHITE)
	fab.add_child(btn)

	fab.set_meta("tex", tex)   # _set_fab_lit toggles the halo on the ART, not the whole fab
	fab.set_meta("lit", true)
	_overlay.add_child(fab)
	# Attached to the ART: the halo hugs the flask's own alpha (the plate would give it the disc's
	# outline instead), and it lands after the fab is in the tree so the glow has a real global
	# transform to bake against.
	Vfx.attach(MERGE_FLASK_GLOW, tex)
	return fab


# ── Quick preview ───────────────────────────────────────────────────────────────

# With Quick preview on and a source picked, every valid partner wears a stand-in card showing the
# RESULT of that pairing. The stand-in is a full-size OVERLAY dropped a little way down its host, so
# the only part of the real card left showing is the strip along its top — its NAME. That is the
# whole statement: "this named card would become this one", nothing has happened yet. It is not
# inset, translucent, or ringed: a second card sitting nearly concentric with the first doubles up
# every badge that overhangs the card rect, and the table turns to noise the moment more than one
# partner is valid. Reconciled from declared state like the rest of the presentation.
#
# Rebuilt ONLY when a pairing actually changes (a signature per entry), never per frame: each
# preview costs a CardData.combine + a CardUI, and this is polled every frame.
func _reconcile_previews() -> void:
	var want: Dictionary = {}   # entry idx -> signature
	if _quick_preview() and _modal == null and _drag.is_empty() and not _fusing \
			and _sel.get("kind", "") == "card":
		var src_idx := int(_sel.get("idx", -1))
		for i in _entries.size():
			if i != src_idx and _can_pair(_sel, i):
				want[i] = "%d|%s" % [src_idx, str((_entries[i].card as DeckCard).id)]

	for i: int in _preview_uis.keys():
		if not want.has(i) or str(_preview_uis[i].get_meta("sig", "")) != str(want[i]):
			_drop_preview(i)

	for i: int in want:
		if _preview_uis.has(i):
			continue
		var verdict := _evaluate_target(_sel, i)
		var inst: CardInstance = verdict.get("preview", null)
		if inst == null:
			continue
		_preview_uis[i] = _make_preview(i, inst, str(want[i]))

	for i in _entries.size():
		_set_host_receded(i, _preview_uis.has(i))
	_fit_previews()


# The card UNDER a stand-in steps back: a touch smaller and dimmer. Without it the two cards read as
# equal claims on the same spot and the eye has to work out which is the real one; receded, the host
# becomes the label its visible strip actually is, and the stand-in owns the read.
#
# Both ride the inner CardUI, never the wrapping item — the item is not the host's alone (the merge
# fab measures against it, the dim-others pass rides its modulate), so writing there would move
# things that must not move. Scale pivots at the TOP CENTRE, not the middle: the only part of the
# host still showing is its top strip, and a centre pivot would slide that strip down under the
# stand-in's top edge, eating the very name this composition exists to show.
const HOST_RECEDE := 0.95
const HOST_RECEDE_DIM := Color(0.72, 0.72, 0.78)

func _set_host_receded(idx: int, on: bool) -> void:
	if idx < 0 or idx >= _entries.size():
		return
	var ui: Variant = _entries[idx].ui
	if not is_instance_valid(ui):
		return   # its wearer was freed by a deck rebuild — the stand-ins go with it
	var card := ui as Control
	var s := Vector2(HOST_RECEDE, HOST_RECEDE) if on else Vector2.ONE
	var m := HOST_RECEDE_DIM if on else Color.WHITE
	if card.scale == s and card.modulate == m:
		return   # polled every frame — write only on a real transition
	card.pivot_offset = Vector2(card.size.x * 0.5, 0.0)
	card.scale = s
	card.modulate = m


# Parks every stand-in over its host: same size, dropped by PREVIEW_DROP. Re-run every reconcile
# because the stand-ins do NOT live on their hosts — they ride the screen overlay (see _make_preview)
# and so have to be told where their card went, which also keeps them true through a reflow glide.
#
# A stand-in hangs BELOW its host, so a card in the bottom row would have its overhang sliced off at
# the scroll viewport's edge — the one place this composition can break. Riding the overlay puts the
# stand-in outside that clip; the price is that a host only PARTLY scrolled into view would wear a
# stand-in floating past the viewport, so those hosts get no stand-in at all. With the table's
# fit-all grid that state only exists for decks big enough to hit the touch floor and scroll.
func _fit_previews() -> void:
	var view := _scroll.get_global_rect()
	for i: int in _preview_uis:
		var holder: Control = _preview_uis[i]
		var host: Variant = _entries[i].item if i < _entries.size() else null
		if not is_instance_valid(host) or not is_instance_valid(holder):
			continue
		var r := (host as Control).get_global_rect()
		holder.visible = view.encloses(r)
		holder.size = r.size
		holder.global_position = r.position + Vector2(0.0, r.size.y * PREVIEW_DROP)


# Builds one stand-in over the card at `idx`: the host's exact size, dropped by PREVIEW_DROP so the
# host's name band stays uncovered, and mouse-transparent so the card underneath still takes every
# tap and drag — the preview is a way of LOOKING at the table, never a new thing to click.
func _make_preview(idx: int, inst: CardInstance, sig: String) -> Control:
	var host: Control = _entries[idx].item
	var holder := Control.new()
	holder.mouse_filter = MOUSE_FILTER_IGNORE
	holder.set_meta("sig", sig)
	holder.size = host.size

	var card := CardUI.create(inst)
	card.draggable = false
	# PASS, not IGNORE: the stand-in is still "a way of LOOKING at the table, never a new thing to
	# click" for the gestures that DO something — left press and drag are seen first by the screen's
	# own _input (which runs before the GUI) and still select and drag the card underneath. What the
	# stand-in claims is the two gestures that only ever ASK A QUESTION: right-click and touch
	# long-press, which CardUI already implements, and which must resolve to the card the player is
	# actually pointing at. Left IGNORE, they fell through to the host and inspected the ORIGINAL —
	# silently the wrong card. The stand-in is flagged phantom, so the inspector it opens is too.
	card.mouse_filter = MOUSE_FILTER_PASS

	# Mounted on the screen overlay, NOT on the host card: the drop hangs the stand-in past its
	# host's bottom edge, which on the last row means past the scroll viewport that would clip it
	# (and everywhere means over the row below, whose cards are later siblings that would paint over
	# it). One move settles both. _fit_previews then parks it on its host every reconcile.
	# First child, so the overlay's own furniture — the per-target merge fabs, the selection pill —
	# keeps drawing above the stand-ins it may overlap.
	_overlay.add_child(holder)
	_overlay.move_child(holder, 0)

	holder.add_child(card)
	card.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	card.custom_minimum_size = Vector2.ZERO

	card.set_phantom(true)   # THE shared "this card isn't real" treatment — see CardUI.set_phantom

	# NO entrance animation, deliberately: the stand-in is simply THERE the moment a pairing becomes
	# valid. A pop-in also can't work here, because _fit_previews parks this node by writing
	# `global_position` every frame — and on a SCALED Control that setter pins the visual top-left
	# corner (the same trap the merge fab's placement documents), so a scale tween would grow the
	# card sideways out of its own left edge instead of in place. The fab reads this node's
	# transform-aware rect, so it would slide and resize right along with it.
	return holder


func _drop_preview(idx: int) -> void:
	var holder: Variant = _preview_uis.get(idx)
	_preview_uis.erase(idx)
	if not is_instance_valid(holder):
		return
	(holder as Control).queue_free()


# Every stand-in, gone — used when the deck itself is rebuilt under them (their hosts are freed,
# so the dictionary would otherwise hold freed nodes).
func _clear_previews() -> void:
	for i: int in _preview_uis.keys():
		_drop_preview(i)
	_preview_uis.clear()


# Whether `p` sits on one of the screen's own floating engage fabs — clicks there are commands
# for those buttons, never dead-space deselects. Tested against the same INSCRIBED CIRCLE the
# button itself answers to (RoundButton._has_point): if the two disagreed, the box corners would
# become dead zones that neither engage nor deselect.
func _click_on_ui(p: Vector2) -> bool:
	for i: int in _merge_btns:
		var b: Variant = _merge_btns[i]
		if is_instance_valid(b) and RoundButton.in_disc(b as Control, p):
			return true
	# The table is only the middle row: the persistent chrome's header (Quick preview / Quick merge)
	# and footer sit OUTSIDE this screen's rect. They are UI, not dead table space — flipping a view
	# toggle must never cost the player the card they had picked.
	if not get_global_rect().has_point(p):
		return true
	# Anything drawn OVER the table that isn't ours — a confirm overlay's scrim and panel, say —
	# is UI too. Checked through the GUI's hover target so it needs no knowledge of who's on top.
	var hovered := get_viewport().gui_get_hovered_control()
	if hovered != null and hovered != self and not is_ancestor_of(hovered):
		return true
	return false


func _on_merge_btn(idx: int) -> void:
	if _sel.is_empty() or _modal != null or not _drag.is_empty() \
			or idx < 0 or idx >= _entries.size():
		return
	var verdict := _evaluate_target(_sel, idx)
	if bool(verdict.get("ok", false)):
		_open_merge(_sel, idx, verdict)


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
# `src_origin`: where the source card visually IS at this instant — a drop's release point. INF
# (the default, and every tap-initiated merge) means "wherever its grid slot is". Only the quick
# path reads it: on the framed path the player releases, reads the framing, then presses Combine,
# by which time the release point is stale and flying from it would read as a teleport.
func _open_merge(src: Dictionary, tgt_idx: int, verdict: Dictionary,
		src_origin: Vector2 = Vector2.INF) -> void:
	if _modal != null:
		return
	# QUICK MERGE: the framing is the confirmation step, so with it switched off there is nothing
	# to open — commit here and let the table show the result. Both gestures (the engage fab and
	# the drop) funnel through this one door, so the fast path lives here rather than in each.
	# Only a pairing that would have been committable anyway takes it: an UNAFFORDABLE merge still
	# opens the framing, because the player needs to be told why nothing happened, and "quick" must
	# never mean "silently does nothing".
	if _quick_merge() and bool(verdict.get("ok", false)) \
			and bool(verdict.get("affordable", true)):
		_quick_commit(src, tgt_idx, verdict, src_origin)
		return
	_cancel_drag()
	# The SOURCE stays selected through the whole procedure — every exit (Cancel, tap-out,
	# right-click, Esc) drops back to it still selected; only a COMMIT moves the selection (to
	# the forged result). Its highlight stays worn under the scrim (see MODAL_LAYER). A
	# drag-initiated merge adopts its source the same way.
	_sel = src
	_merge = {"src": src, "tgt": tgt_idx, "verdict": verdict}

	_modal_layer = CanvasLayer.new()
	_modal_layer.layer = MODAL_LAYER
	add_child(_modal_layer)

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
			_swallow_release = true   # this click is INTERACTIVE (it closes) — eat its release
			_close_modal())
	_modal_layer.add_child(dim)
	_modal = dim

	# Capture the anchor BEFORE any layout below: the framing centres on the target card's spot.
	var anchor := (_entries[tgt_idx].item as Control).get_global_rect().get_center()
	_build_cluster(src, tgt_idx, verdict)
	_place_cluster(anchor)


# Builds the framing cluster: [components] · [enlarged result] · [details], buttons beneath.
func _build_cluster(src: Dictionary, tgt_idx: int, verdict: Dictionary) -> void:
	var enchanting := str(src.get("kind", "")) == "charm"
	var result_inst: CardInstance = verdict.get("preview", null)

	# Sizes flow from the RESULT card: comfortably larger than a grid card, capped by the screen.
	var res_h := clampf(_live_card_size().y * 1.7, 300.0, size.y * 0.52)
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
		# STOP (not IGNORE): the enlarged result behaves like any card — right-click opens the full
		# CardInspector. NO hover details here, deliberately: the result's whole read is already
		# rendered beside it and stays there (see the details column below), so a panel repeating it
		# on hover would cover the framing to say what the framing is already saying.
		big.mouse_filter = MOUSE_FILTER_STOP
		holder.add_child(big)
		# The composited radiance is attached LATER (after _place_cluster sizes/positions the
		# framing), so its first silhouette bake lands on the real, settled rect.

	# Small breathing gap between the result card and its read — the description box shouldn't
	# hug the card's frame.
	var det_margin := MarginContainer.new()
	det_margin.add_theme_constant_override("margin_left", 18)
	row.add_child(det_margin)

	# Details column: verdict line (only when blocking) over THE standard card read —
	# CardTooltip.build_details, the exact composition every hover panel and the CardInspector
	# show (description, targeting policy, building note, abilities, charms, statuses). A
	# bespoke read here would drift the moment cards grow a new section; this one can't. It
	# sits on the tooltip's own dark surface — its palette is light-on-dark by design.
	var det_col := VBoxContainer.new()
	det_col.size_flags_vertical = SIZE_SHRINK_CENTER
	det_col.add_theme_constant_override("separation", 10)
	det_margin.add_child(det_col)
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
		# Column-flow budget = the result card's height: an ability-heavy result widens the
		# framing with extra read columns instead of pushing the buttons down (the modal's
		# width is free real estate; its height is not).
		det_panel.add_child(CardTooltip.build_details(result_inst, det_s, res_h))
		det_col.add_child(det_panel)

	# The decision row: Cancel pinned to the framing's FAR LEFT, the big commit button centred ON
	# the result card and ~30% wider than it — the primary action reads as belonging to the card,
	# not to the panel. A plain Control (not an HBox): the commit anchors to the CARD's centre,
	# which only exists once the row is laid out — _place_cluster does the actual placement.
	var buttons := Control.new()
	buttons.custom_minimum_size.y = MERGE_BTN_H
	col.add_child(buttons)
	var cancel := ScreenUI.action_button(Loc.t("common.cancel"), _close_modal,
		Vector2(150, MERGE_BTN_H), 26, ScreenUI.CHROME_NEUTRAL)
	buttons.add_child(cancel)
	var commit_text: String = Loc.t("combine.attach") if enchanting \
		else Loc.t("combine.combine_cost", {"n": int(verdict.get("cost", 0))})
	var commit := ScreenUI.action_button(commit_text, _commit_merge,
		Vector2(0, MERGE_BTN_H), 32, ScreenUI.CHROME_CONFIRM)
	commit.disabled = not bool(verdict.get("affordable", true))
	buttons.add_child(commit)
	_commit_btn = commit
	# The commit button's ready-glow is attached LATER (see _place_cluster) — same reason as the
	# result radiance: bake on the settled rect, not the pre-layout zero-size one.


# Positions the framing over the target card's grid spot (clamped fully on-screen) and pops it in.
func _place_cluster(global_anchor: Vector2) -> void:
	var panel := _cluster
	panel.modulate.a = 0.0
	# TWO frames, then size from the COMPUTED MINIMUM — not `panel.size`. The cluster is parented
	# to a plain ColorRect (not a container), so nothing stretches it: read too early, panel.size
	# is (0,0), the placement anchors the TOP-LEFT at the card and the framing overflows the
	# screen. get_combined_minimum_size is bottom-up and reliable once the nested column-flow
	# labels have had a layout pass to report their real heights.
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(panel) or _modal == null:
		return
	var psize := panel.get_combined_minimum_size()
	if psize.x < 1.0 or psize.y < 1.0:
		psize = panel.size
	panel.size = psize
	panel.pivot_offset = psize * 0.5

	# Never overflow: a framing larger than the screen (an ability-heavy result flowing into extra
	# columns) is scaled down uniformly to fit within the margins.
	var margin := 12.0
	var avail := _modal.size - Vector2(margin, margin) * 2.0
	var fit := clampf(minf(minf(avail.x / psize.x, avail.y / psize.y), 1.0), 0.3, 1.0)
	var scaled := psize * fit

	# Centre the (scaled) framing on the target card's spot, clamped fully on-screen.
	var center: Vector2 = _modal.get_global_transform().affine_inverse() * global_anchor
	center.x = clampf(center.x, margin + scaled.x * 0.5,
			maxf(_modal.size.x - margin - scaled.x * 0.5, margin + scaled.x * 0.5))
	center.y = clampf(center.y, margin + scaled.y * 0.5,
			maxf(_modal.size.y - margin - scaled.y * 0.5, margin + scaled.y * 0.5))
	panel.position = center - psize * 0.5   # unscaled top-left; the pivot-centred scale holds `center`

	# One frame for the children to lay out at the assigned size before the button geo reads their
	# rects (still at scale 1 here, so global rects == panel-local — the scale is applied after).
	await get_tree().process_frame
	if not is_instance_valid(panel) or _modal == null:
		return

	# Decision-row geometry: Cancel hugs the row's far left; the commit button sits centred under
	# the RESULT CARD, ~30% wider than it — it belongs to the card, visually and spatially.
	if _commit_btn != null and _result_holder != null and is_instance_valid(_result_holder):
		var buttons := _commit_btn.get_parent() as Control
		var cancel := buttons.get_child(0) as Control
		cancel.position = Vector2.ZERO
		var w := _result_holder.size.x * 1.3
		var cx := _result_holder.global_position.x + _result_holder.size.x * 0.5 \
				- buttons.global_position.x
		_commit_btn.size = Vector2(w, MERGE_BTN_H)
		_commit_btn.position = Vector2(
			clampf(cx - w * 0.5, cancel.size.x + 14.0, maxf(buttons.size.x - w, cancel.size.x + 14.0)),
			0.0)

	panel.scale = Vector2(fit, fit) * 0.92
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, 0.14)
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "scale", Vector2(fit, fit), 0.18)

	# NOW attach the composited cues — the framing is sized, positioned and about to settle at
	# `fit`, so each silhouette bakes on a real rect and (with GlowFx's continuous follow) tracks
	# the pop tween and the fit-scale without drifting.
	if _result_holder != null and is_instance_valid(_result_holder):
		for cue: String in RESULT_READY_CUES:
			Vfx.attach(cue, _result_holder)
	if _commit_btn != null and is_instance_valid(_commit_btn) and not _commit_btn.disabled:
		for cue: String in COMBINE_READY_CUES:
			Vfx.attach(cue, _commit_btn)


# A component mini-card for the framing's ingredients column.
func _make_component_card(inst: CardInstance, comp_size: Vector2) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = comp_size
	holder.size_flags_horizontal = SIZE_SHRINK_CENTER
	var ui := CardUI.create(inst)
	ui.draggable = false
	ui.custom_minimum_size = Vector2.ZERO
	ui.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	ui.mouse_filter = MOUSE_FILTER_PASS   # it still answers the pointer inside the framing
	# The ingredients are the one thing in the framing with no read of its own — the result has its
	# details column, these have a picture. So they open theirs on hover like a card anywhere else.
	# Nothing is wired to their press (the framing is a modal; there is nothing to pick here), so
	# the surface says they are live — asked of the live tree, never latched (see interactive_check).
	ui.interactive_check = func(c: CardUI) -> bool: return c.get_parent() == holder
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


# Closes the merge procedure back to the table — the SELECTION is untouched (closing the modal
# is an interactive act, never a deselect). Safe to call anytime outside a fusion.
func _close_modal() -> void:
	if _fusing:
		return
	_drop_cluster()
	if _modal_layer != null:
		_modal_layer.queue_free()   # takes the dim + fusion + toast with it
	_modal_layer = null
	_modal = null
	_merge = {}
	_fuse_anim = null
	# Toast dismissed mid-flight: the anim just died with the modal, so touchdown will never
	# fire — land the forged card by hand (unhide its shell wherever the glide has it).
	if _pending_land != null:
		var idx := _entry_index_of(_pending_land)
		_pending_land = null
		if idx >= 0:
			(_entries[idx].item as Control).visible = true


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
# Combine plays the fusion sequence (the destructive deck mutation commits at its fly start).
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
	_start_fusion(int(src.get("idx", -1)), tgt, verdict.get("result_dc", null), _modal)


# The quick-merge commit: the same act the framing's Combine/Attach button performs, minus the
# framing and minus the celebration toast. The FUSION still plays — that animation is the merge
# happening on the table, not a modal step, and without it two cards would silently blink into one.
# It runs on the screen's own overlay rather than a scrim layer, so the table stays live underneath:
# nothing is covered, nothing has to be dismissed, and the player can immediately chain into the
# next merge.
func _quick_commit(src: Dictionary, tgt_idx: int, verdict: Dictionary,
		src_origin: Vector2 = Vector2.INF) -> void:
	if _fusing:
		return
	_cancel_drag()
	_sel = src
	_merge = {}
	if str(src.get("kind", "")) == "charm":
		_do_enchant(str(src.get("id", "")), tgt_idx)
		return
	_quick_fusing = true
	_start_fusion(int(src.get("idx", -1)), tgt_idx, verdict.get("result_dc", null), _overlay,
			src_origin)
	if not _fusing:
		_quick_fusing = false   # the fusion refused to start; don't strand the flag


# Tears down after a quick-merge fusion — the counterpart of the framed path's toast + _close_modal,
# with neither to click through.
func _end_quick_fusion() -> void:
	if _fuse_anim != null:
		_fuse_anim.queue_free()
		_fuse_anim = null
	_fusing = false
	_quick_fusing = false


# ── Fusion (combine commit) ─────────────────────────────────────────────────────

# Flies the two GRID cards (as clones, at their real grid size + spots) together into their
# midpoint, then flies the forged result back onto its grid slot. The clones read as the actual
# table cards lifting off and slamming together, not something conjured by the modal.
# The deck COMMITS AT FLY START (see _commit_fusion): the fusion is already irreversible here —
# cost paid — so the data moves first. The TABLE holds perfectly still through the merge itself:
# both originals just hide (their clones are the cards now) and their two holes stay open. Then
# the finale is ONE simultaneous movement — at the anim's `returning` beat the table reorganizes
# (one glide) while the forged card flies from the midpoint straight onto its FINAL slot in that
# new layout (FitGrid.target_global_rect — the flight outlasts the glide, so it lands on a card
# at rest). The impact beat is sensory only (SFX + element burst).
# `host` parents the animation (and the element burst marker): the modal's dim on the framed path,
# the screen's overlay on the quick one. Everything else about the sequence is identical, from
# the one code path.
func _start_fusion(src_idx: int, tgt_idx: int, result_dc: DeckCard, host: Control,
		src_origin: Vector2 = Vector2.INF) -> void:
	if _fusing or result_dc == null or host == null:
		return
	_fusing = true

	# Fly FROM the two grid cards' own spots (their rect CENTRES — unaffected by the source's
	# highlight scale, which is pivot-centred), to their midpoint, at real grid size. This is
	# what makes the fusion read as the table cards themselves converging. A dropped source
	# overrides its spot with the release point, so the card continues from where the hand left
	# it — snapping back to the grid first would break the one continuous gesture in two.
	# Everything below is captured BEFORE the commit reshuffles the table.
	var a_gc := src_origin if src_origin.is_finite() \
			else (_entries[src_idx].item as Control).get_global_rect().get_center()
	var b_gc := (_entries[tgt_idx].item as Control).get_global_rect().get_center()
	var center := (a_gc + b_gc) * 0.5
	var fly_size := _live_card_size()

	var a_inst := (_entries[src_idx].card as DeckCard).make_instance()
	var b_inst := (_entries[tgt_idx].card as DeckCard).make_instance()
	var result_inst := result_dc.make_instance()
	var color_a := _color_for_card(_entries[src_idx].data)
	var color_b := _color_for_card(_entries[tgt_idx].data)
	var tgt_dc: DeckCard = _entries[tgt_idx].card

	_drop_cluster()

	# Both originals hide (their clones ARE those cards now) but keep their grid slots — the
	# table stays frozen mid-spectacle. The selection clears: mid-fusion nothing should wear the
	# highlight or grow engage fabs off stale, part-hidden entries.
	(_entries[src_idx].item as Control).visible = false
	(_entries[tgt_idx].item as Control).visible = false
	_sel = {}
	if not _commit_fusion(src_idx, tgt_idx, result_dc):
		(_entries[src_idx].item as Control).visible = true
		(_entries[tgt_idx].item as Control).visible = true
		_fusing = false
		return
	_pending_land = tgt_dc

	var anim := ForgeFuseAnim.new()
	anim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	# The impact beat: the combine SFX (the merge itself already happened at fly start).
	anim.flashed.connect(func() -> void: Sfx.combined())
	# Return-flight start: reorganize the table NOW — the reconcile runs synchronously, so by the
	# time the anim queries `dest` the new layout's targets are in place. A pure reorder: the
	# target's face was already swapped at commit, so this frame builds nothing heavyweight.
	# The framed path's toast pops on this same beat — the merge reveal is complete, so the
	# celebration announces itself IMMEDIATELY while the table tidies up behind/beneath it,
	# instead of ambushing the player after a finale they were still watching.
	anim.returning.connect(func() -> void:
		_rebuild_deck()
		if not _quick_fusing:
			_show_result_toast(result_inst, Loc.t("combine.forged")))
	anim.finished.connect(_on_fuse_landed.bind(tgt_dc))
	host.add_child(anim)
	_fuse_anim = anim

	# The merge impact announces the newborn card's element: the combine element-variant bursts
	# at the collision point exactly on the impact beat. No variant live (or placeholders
	# muted) = the anim's own spark splash carries the moment, as before.
	var combine_vid := Vfx.resolve("combine", result_inst.data.elements)
	if not combine_vid.is_empty():
		var marker := Control.new()
		marker.mouse_filter = MOUSE_FILTER_IGNORE
		marker.size = Vector2(120, 120)
		host.add_child(marker)
		# On the framed path the marker died with the modal layer; the quick path's host is the
		# screen's own long-lived overlay, so it has to clear up after itself or every quick merge
		# would leave one behind.
		anim.finished.connect(marker.queue_free)
		marker.global_position = center - marker.size * 0.5
		anim.flashed.connect(func() -> void: Vfx.play(combine_vid, marker))

	# The landing slot, queried at return-flight start — right after the reflow above launches.
	# The shell is mid-glide then, so the answer is its TARGET rect in the new layout, not its
	# live one; the flight and the glide converge on the same point.
	var dest := func() -> Rect2:
		var i := _entry_index_of(tgt_dc)
		if i >= 0:
			return _fit_grid.target_global_rect(_entries[i].item as Control)
		return Rect2(center - fly_size * 0.5, fly_size)

	anim.play(a_inst, b_inst, result_inst, a_gc, b_gc, center, fly_size, color_a, color_b,
			OK_COLOR, dest)


# The data half of the fusion, run at FLY START (the act is already irreversible — cost checked,
# input locked). THE TARGET BECOMES THE RESULT: the same DeckCard object takes on the forged
# definition (id/override/charms — so its grid node survives the later reconcile and its deck
# position holds), and the deck op reduces to removing the source. NO reflow here — the table's
# _entries stay deliberately stale (frozen layout) until the anim's `returning` beat. The cost
# is recomputed
# here (the single commit point) so it can never drift from what the preview quoted; the guard
# is belt-and-braces against a stale UI.
func _commit_fusion(src_idx: int, tgt_idx: int, result_dc: DeckCard) -> bool:
	var cost := ForgeCosts.merge_cost(_entries[src_idx].data as CardData,
			_entries[tgt_idx].data as CardData)
	if GameData.current_run.magic_mineral < cost:
		return false
	GameData.current_run.magic_mineral -= cost
	var tgt_dc: DeckCard = _entries[tgt_idx].card
	tgt_dc.id = result_dc.id
	tgt_dc.override = result_dc.override
	tgt_dc.charms = result_dc.charms
	GameData.current_run.deck.remove_at(int(_entries[src_idx].deck_idx))
	GameData.save_run()
	# The face swap happens NOW, while the table is frozen and the shell is hidden — building a
	# CardUI on the finale's launch frame (where the reflow + return flight start together) would
	# hitch the exact moment that must run clean.
	_refresh_face(_entries[tgt_idx])
	return true


# Touchdown: the table settled with the flight (same clock), and the clone now sits exactly on
# the shell's final rect — unhide it and the swap is invisible (the quick path frees the anim
# right here; the framed path's clone lives until the modal closes, under the already-showing
# toast). The selection stays clear — landing on a reorganized table already reads as enough of
# a change; forcing a selection on top of it grays out every non-partner card unprompted.
func _on_fuse_landed(tgt_dc: DeckCard) -> void:
	_pending_land = null
	var idx := _entry_index_of(tgt_dc)
	if idx >= 0:
		(_entries[idx].item as Control).visible = true
	if _quick_fusing:
		_end_quick_fusion()   # no toast to click through — that's the whole point of quick merge


func _entry_index_of(dc: DeckCard) -> int:
	for i in _entries.size():
		if _entries[i].card == dc:
			return i
	return -1


# The celebration toast: a BIG, readable reveal of the forged card centred over the dim — the
# new card blown up beside its full read, taking real advantage of the screen. Clicking the dim
# (outside the panel) closes the whole modal; the panel swallows its own clicks, so it's a true
# "click out to dismiss". The merge is already committed by this point.
func _show_result_toast(result_inst: CardInstance, title_text: String) -> void:
	if _modal == null or result_inst == null:
		return
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	_modal.add_child(center)

	var panel := PanelContainer.new()
	# The toast says "tap anywhere", so anywhere has to mean anywhere — including the panel itself
	# (see the catcher at the end of this method, which is what actually guarantees it).
	panel.mouse_filter = MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(ScreenUI.SURFACE_DEEP, 0.98)
	style.set_border_width_all(2)
	style.border_color = ScreenUI.SURFACE_DEEP_BORDER
	style.set_corner_radius_all(18)
	style.set_content_margin_all(36)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	Vfx.play("ui_toast_glint", panel)   # the notice announces itself (carries its sound)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 22)
	panel.add_child(col)

	# A big celebratory banner.
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", OK_COLOR)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	title.add_theme_constant_override("outline_size", 5)
	col.add_child(title)

	# The star: the forged card blown up, beside its full read (same dark surface as the framing
	# / inspector, column-flowing to the card's height for an ability-heavy result).
	var card_h := clampf(size.y * 0.55, 380.0, 660.0)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 30)
	col.add_child(row)

	var holder := Control.new()
	holder.custom_minimum_size = Vector2(card_h / CARD_ASPECT, card_h)
	holder.size_flags_vertical = SIZE_SHRINK_CENTER
	var card := CardUI.create(result_inst)
	card.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	card.custom_minimum_size = Vector2.ZERO
	card.mouse_filter = MOUSE_FILTER_IGNORE
	holder.add_child(card)
	row.add_child(holder)

	var det_panel := PanelContainer.new()
	var det_style := StyleBoxFlat.new()
	det_style.bg_color = CardTooltip.BG_COLOR
	det_style.set_border_width_all(1)
	det_style.border_color = CardTooltip.BORDER_COLOR
	det_style.set_corner_radius_all(10)
	det_style.set_content_margin_all(18)
	det_panel.add_theme_stylebox_override("panel", det_style)
	det_panel.size_flags_vertical = SIZE_SHRINK_CENTER
	det_panel.add_child(CardTooltip.build_details(result_inst, 1.45, card_h))
	row.add_child(det_panel)

	var hint := Label.new()
	hint.text = Loc.t("combine.tap_continue")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color(0.74, 0.74, 0.82))
	col.add_child(hint)

	# The fusion's finale (return flight + table glide) keeps playing BENEATH the toast — the anim
	# lives until the modal closes. Re-arm click-to-dismiss now; if the player dismisses before
	# touchdown, _close_modal's _pending_land rescue unhides the forged card. The toast pops in
	# (fade + slight scale) as its own little celebration beat.
	_fusing = false
	center.modulate.a = 0.0
	await get_tree().process_frame
	if not is_instance_valid(panel) or _modal == null:
		return
	panel.pivot_offset = panel.size * 0.5
	panel.scale = Vector2(0.9, 0.9)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(center, "modulate:a", 1.0, 0.18)
	tw.tween_property(panel, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# THE DISMISS SURFACE. The hint promises a tap anywhere continues, and the dim behind the toast
	# only delivers that for taps that MISS the panel — the panel and its contents (the result card,
	# the details block, every label inside them) each answer for their own rect, so a tap on the very
	# thing the player is looking at did nothing. Rather than chase mouse_filter through that whole
	# subtree — and have the promise silently break again the next time the toast grows a child —
	# one transparent catcher goes over the lot. Added last, so it sits above the toast in input
	# order, and it lives on the modal layer so it dies with the rest of it.
	var catcher := Control.new()
	catcher.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	catcher.mouse_filter = MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(e: InputEvent) -> void:
		if _fusing:
			return
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_swallow_release = true   # this click is INTERACTIVE (it closes) — eat its release
			_close_modal())
	_modal.add_child(catcher)


# ── Apply ──────────────────────────────────────────────────────────────────────
# (The combine's data commit lives with its choreography — see _commit_fusion.)

func _do_enchant(charm_id: String, tgt_idx: int) -> void:
	var dc: DeckCard = _entries[tgt_idx].card
	# Spend the charm only if it actually went on. The verdict already refused a full card, so this
	# can't normally fail — but consuming an inventory charm that never attached is the one way this
	# flow could destroy a player's item, and the check costs nothing.
	if not dc.add_charm(charm_id):
		return
	GameData.current_run.charms.erase(charm_id)
	GameData.save_run()
	Sfx.combined()
	# The enchanted card's face went stale (new charm pip) — rebuild that one node in place;
	# everything else survives untouched.
	_rebuild_deck([dc])
	_rebuild_charms()


# ── Particles ──────────────────────────────────────────────────────────────────

# Half-extents of the particle path. Start from the card's half-size, scale it by
# ForgeFX.AURA.radius_scale (the main handle — 1.0 = on the edge, >1 = wider, <1 = tighter), then
# add ForgeFX.AURA.margin for a flat px nudge on top. Tweak `radius_scale` to resize the ring.
func _card_aura_radii() -> Vector2:
	var fscale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	var cs := _live_card_size()
	return Vector2(cs.x * 0.5 * fscale + margin, cs.y * 0.5 * fscale + margin)


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
