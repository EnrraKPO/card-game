class_name Hand
extends Node

# PRESENTS the player's hand — the bar at the screen's bottom edge, salvaged from the
# pre-swap tree one behavior at a time (docs/planning/RULINGS.html R7). THIS SLICE IS THE
# BAR ALONE: the panel, the padded scrolling strip, and the row of card faces rendered from
# an injected HandView. The behaviors the old bar carried — hover lift, the play-me glow,
# drag origination, the inspect sidebar and its navigation levels, the ability tray —
# return as their own recorded atoms.
#
# THE WIDGET NEVER READS THE GAME WORLD (R4): set_hand(HandView) is its one input, and the
# per-card hand-relational states (affordable, pickable) arrive on the HandItemView wrapper
# (R8) — the hand arranges cards and hands them things, never reaches inside them
# (R6/R7); a card face stays exactly what CardUI renders anywhere else.

# A press on the `index`-th card of the fan. The host owns what a press means (play it,
# answer a pick with it, toggle its selection) — the bar only reports where the finger
# landed.
signal card_pressed(index: int)

# The selected hand card changed (null = nothing selected). The host lights the board's
# static "place here" cues for the selection.
signal selection_changed(ui: CardUI)

# Card selection is only honoured while the host has placement input enabled (i.e. during
# the player's command span). Toggled via set_input_enabled().
var selection_enabled: bool = false

# Wires a hand UNIT card so its drag lights the board's move/place cues; injected by the
# host (the fight connects drag start/end to its Interaction session).
var wire_unit_card: Callable

# An ability token was pressed on an OWN unit's tray — the host owns what activation means
# (it emits the use_ability ask). Enemy tokens are view-only and never emit.
signal ability_pressed(ability_name: StringName)

# The hand panel's navigation levels: the plain hand row, the Abilities list (fielded units
# with an ability, an inspection menu), and the single-unit inspection view. One
# always-visible button column drives them (see _set_level); the panel's height never
# changes.
enum NavLevel { HAND, ABILITIES, INSPECT }

# The inspect sidebar's WIDTH BUDGET and its text sizing. The cap is a budget decision, not
# a readability one: the sidebar is REFERENCE (what the unit you already clicked is), the
# ability strip beside it is the ACTIONABLE content, and the two compete for one fixed bar.
const DESC_MAX_W := 240.0
const DESC_NAME_FONT := 28
const DESC_FONT_MAX := 26
const DESC_FONT_MIN := 16
# The Inspect Abilities button's base colour — fuchsia, deliberately loud: the gateway to
# abilities must not read as chrome.
const INSPECT_ACCENT := Color("d92bc4")
# Light body text for the ability descriptions, which sit on the dark hand-bar strip.
const ABILITY_TEXT_COLOR := Color(0.95, 0.93, 0.86)

var _nav_level: NavLevel = NavLevel.HAND
# What the sidebar/tray currently render (injected — see set_inspect / set_ability_roster;
# the host composes both from the engine, the bar renders and never asks).
var _inspect: HandInspectView = null
var _roster: Array[HandInspectView] = []
var _gen_cards: Array = []        # the inspect view's ability token widgets
var _ability_entries: Array = []  # the Abilities level's holder entries
var _gen_box: BoxContainer
var _abilities_box: BoxContainer
var _no_abilities_lbl: Label
var _desc_panel: PanelContainer
var _desc_hbox: HBoxContainer
var _desc_clip: Control
var _desc_col: VBoxContainer
var _desc_name_lbl: Label
var _desc_text_lbl: Label
var _desc_preview: CardUI = null
var _inspect_abilities_btn: Button
var _back_btn: Button

# One card size for the whole screen: matches the authored slot footprint so a card is the
# same object at the same scale whether it's in the hand or on the field. Hosts adopt the
# board's computed size through set_card_size.
const CARD_SIZE := Vector2(220, 288)

# How far the hand bar deliberately hangs BELOW the screen's bottom edge (the host pulls its
# body margin down by this much). The cropped band is dead card frame: the lowest stat gem
# (the speed badge) ends at ~96% of the card's height — 288×4% ≈ 11.5px of empty border —
# so 8 crops only frame while leaving the gems a few px of visible clearance.
const BOTTOM_BLEED := 8.0

# The bar's one vertical pad, above the cards (none below — see build_into). Public because
# it's a term in the host's shared-card-size solve: bar height = card height + this.
const PAD_TOP := 6.0

# The unaffordable dressing: the card dims to this — present, readable, visibly not a play.
const UNAFFORDABLE_DIM := Color(0.55, 0.55, 0.6)
# The pick-candidate dressing: the same green the fight's other candidate surfaces wear.
const PICKABLE_TINT := Color(0.6, 1.0, 0.6)

var _view: HandView = null
var _hand_cards: Array = []  # Array[CardUI], one per view item, in item order
var _card_size: Vector2 = CARD_SIZE

var _panel: PanelContainer
var _pad: MarginContainer
var _scroll: ScrollContainer
var _content: HBoxContainer   # the strip's one content row
var _hand_box: BoxContainer


# ── UI construction ──────────────────────────────────────────────────────────────

# `left_widget` (optional) is mounted as the bar's LEFTMOST column, spanning the full bar
# height — the fight hands its mana reading in here, since mana is what the hand spends.
func build_into(parent: Control, left_widget: Control = null) -> void:
	_panel = PanelContainer.new()
	# Card height + the top pad only — the cards sit flush at the bar's bottom, whose last
	# BOTTOM_BLEED px hang off-screen (see the consts above).
	_panel.custom_minimum_size.y = _card_size.y + PAD_TOP
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_panel)

	var outer_row := HBoxContainer.new()
	outer_row.add_theme_constant_override("separation", 16)
	outer_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_row.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_panel.add_child(outer_row)

	if left_widget != null:
		outer_row.add_child(left_widget)

	# Padding inside the hand bar: the row breathes off the top of the bar. NO left padding —
	# the left widget (plus the row's own separation) already stands between the first card and
	# the screen edge, so more inset there is dead space. NO bottom padding: the cards sit
	# flush at the bar's bottom edge so the off-screen bleed (BOTTOM_BLEED) crops only their
	# dead sub-gem frame, not empty panel.
	_pad = MarginContainer.new()
	_pad.add_theme_constant_override("margin_left", 0)
	_pad.add_theme_constant_override("margin_right", 20)
	_pad.add_theme_constant_override("margin_top", int(PAD_TOP))
	_pad.add_theme_constant_override("margin_bottom", 0)
	_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pad.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	outer_row.add_child(_pad)

	# THE fixed-WIDTH guarantee: the strip is the bar's only column whose content has no upper
	# bound, so it must NEVER report that content's width as a minimum. Horizontal scrolling
	# stays enabled, which is what keeps a ScrollContainer's own minimum width at zero; the
	# strip then takes exactly the width the fixed columns leave, and overflow scrolls.
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.resized.connect(_sync_strip_clip)
	_pad.add_child(_scroll)

	# The inspect sidebar: one panel, hidden entirely outside the raised levels. Flush to the
	# bar's own edges — light SURFACE_DEEP background, same as CardTooltip: the dark
	# description text is illegible against the hand bar's dark theme without it.
	_desc_panel = PanelContainer.new()
	_desc_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_panel.visible = false
	var desc_style := StyleBoxFlat.new()
	desc_style.bg_color = ScreenUI.SURFACE_DEEP
	desc_style.set_content_margin_all(0)
	_desc_panel.add_theme_stylebox_override("panel", desc_style)
	outer_row.add_child(_desc_panel)

	_desc_hbox = HBoxContainer.new()
	_desc_hbox.add_theme_constant_override("separation", 14)
	_desc_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_panel.add_child(_desc_hbox)

	var desc_text_wrap := MarginContainer.new()
	desc_text_wrap.add_theme_constant_override("margin_left", 14)
	desc_text_wrap.add_theme_constant_override("margin_top", 10)
	desc_text_wrap.add_theme_constant_override("margin_right", 10)
	desc_text_wrap.add_theme_constant_override("margin_bottom", 10 + int(BOTTOM_BLEED))
	desc_text_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_text_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_hbox.add_child(desc_text_wrap)

	# THE fixed-height guarantee: a plain Control (NOT a container) never adds its children's
	# minimum size to its own, so however tall the description wraps, it can't push the hand
	# bar past its fixed height. Overflow past the fixed height is clipped.
	_desc_clip = Control.new()
	_desc_clip.clip_contents = true
	_desc_clip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_desc_clip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_text_wrap.add_child(_desc_clip)

	_desc_col = VBoxContainer.new()
	_desc_col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_desc_col.add_theme_constant_override("separation", 12)
	_desc_clip.add_child(_desc_col)

	_desc_name_lbl = Label.new()
	_desc_name_lbl.add_theme_font_size_override("font_size", DESC_NAME_FONT)
	_desc_col.add_child(_desc_name_lbl)

	_desc_text_lbl = Label.new()
	_desc_text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_text_lbl.add_theme_font_size_override("font_size", DESC_FONT_MAX)
	_desc_text_lbl.add_theme_color_override("font_color", Color("3a2f22"))
	_desc_text_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_col.add_child(_desc_text_lbl)

	# The navigation button column at the far right of the bar — ALWAYS present, one column
	# for every level so the actions live in the same place throughout.
	var nav_wrap := MarginContainer.new()
	nav_wrap.add_theme_constant_override("margin_left", 16)
	nav_wrap.add_theme_constant_override("margin_right", 16)
	nav_wrap.add_theme_constant_override("margin_top", 16)
	nav_wrap.add_theme_constant_override("margin_bottom", 16 + int(BOTTOM_BLEED))
	nav_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_row.add_child(nav_wrap)

	var nav_box := HBoxContainer.new()
	nav_box.add_theme_constant_override("separation", 10)
	nav_wrap.add_child(nav_box)

	# The door to the Abilities list — tall, narrow, fuchsia: the hand bar's landmark.
	_inspect_abilities_btn = ScreenUI.action_button(Loc.t("hand.inspect_abilities"),
			show_abilities, Vector2(175, 64), 28, INSPECT_ACCENT)
	_inspect_abilities_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspect_abilities_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_inspect_abilities_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_inspect_abilities_btn.visible = false
	nav_box.add_child(_inspect_abilities_btn)

	# Straight back to the plain hand, from either raised level.
	_back_btn = ScreenUI.action_button(Loc.t("hand.back_to_hand"),
			_on_back_to_hand, Vector2(175, 56), 20, ScreenUI.CHROME_NEUTRAL)
	_back_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_back_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_back_btn.visible = false
	nav_box.add_child(_back_btn)
	for st: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb: StyleBox = _back_btn.get_theme_stylebox(st)
		sb.content_margin_left = 16.0
		sb.content_margin_right = 16.0

	# The three content rows occupy the same strip and show one at a time (see _set_level).
	# SHRINK_CENTER vertically so every card sits on the same centreline.
	_content = HBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	_content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.resized.connect(_sync_strip_clip)
	_scroll.add_child(_content)

	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 12)
	_hand_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_hand_box)

	_gen_box = HBoxContainer.new()
	_gen_box.add_theme_constant_override("separation", 12)
	_gen_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gen_box.visible = false
	_content.add_child(_gen_box)

	# Shown in the token row's place when the inspected unit offers no abilities, so the
	# inspect view says why that space is empty instead of just being empty.
	_no_abilities_lbl = Label.new()
	_no_abilities_lbl.text = Loc.t("hand.no_abilities")
	_no_abilities_lbl.add_theme_font_size_override("font_size", 20)
	_no_abilities_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	_no_abilities_lbl.custom_minimum_size.y = _card_size.y
	_no_abilities_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_no_abilities_lbl.visible = false
	_content.add_child(_no_abilities_lbl)

	_abilities_box = HBoxContainer.new()
	_abilities_box.add_theme_constant_override("separation", 12)
	_abilities_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_abilities_box.visible = false
	_content.add_child(_abilities_box)


# ── The one input ────────────────────────────────────────────────────────────────

# Injects the hand's whole presentation and re-renders the row — RECONCILED by each item's
# subject, never rebuilt wholesale: the old hand kept its card nodes stable across every
# refresh (rebuilding only on draw/discard), and a live gesture (a selection, a glow, a
# drag) must never have its card freed out from under it by a repaint.
func set_hand(view: HandView) -> void:
	_view = view
	var kept: Dictionary = {}
	for ui: CardUI in _hand_cards:
		if is_instance_valid(ui):
			kept[ui.view_subject] = ui
	_hand_cards.clear()
	if _view != null:
		for item: HandItemView in _view.items:
			var ui := kept.get(item.subject) as CardUI
			if ui == null:
				ui = CardUI.create(item.card, true)
				ui.view_subject = item.subject
				# A press reports the item's CURRENT index — looked up live, since
				# reconciliation reorders without rewiring.
				ui.pressed.connect(_on_card_pressed.bind(ui))
				# THE HAND IS THE ONE SURFACE THAT LIFTS. A hand card stands nowhere, so its
				# position carries no meaning to spend. Installed as a RULE the card asks:
				# THIS node is reparented into a board slot when played, so "was dealt by the
				# hand" and "is in the hand" are different facts; only the second may lift.
				ui.lift_check = func(c: CardUI) -> bool:
					return c.get_parent() == _hand_box
				# A unit card is draggable out of the hand (a spell casts by click for now);
				# the host's wire routes its drag into the interaction session.
				if item.card.card_type == CardData.CardType.UNIT:
					ui.draggable = true
					if wire_unit_card.is_valid():
						wire_unit_card.call(ui)
				_hand_box.add_child(ui)
			else:
				kept.erase(item.subject)
				ui.card_data = item.card
				ui.refresh()
			ui.custom_minimum_size = _card_size
			ui.set_status_views(item.statuses)
			_apply_item_states(ui, item)
			# The playability RULE (see CardUI.set_playable_check) — re-installed each
			# injection so it closes over the CURRENT item's composed affordability (R8),
			# the seam's answer to the old mana read.
			ui.set_playable_check(func(c: CardUI) -> bool:
				return c.get_parent() == _hand_box and selection_enabled and item.affordable)
			_hand_cards.append(ui)
	# Departed items' cards go; surviving ones take the view's order.
	for leftover: Variant in kept:
		var gone := kept[leftover] as CardUI
		_hand_box.remove_child(gone)
		gone.queue_free()
	for index: int in _hand_cards.size():
		_hand_box.move_child(_hand_cards[index], index)


func _on_card_pressed(ui: CardUI) -> void:
	var index := _hand_cards.find(ui)
	if index >= 0:
		card_pressed.emit(index)


# The hand-relational dressings, applied BY the hand ONTO its arrangement of the card — the
# face itself is never asked to know them (R8). Both ride the root modulate, which the card's
# own treatments deliberately leave free.
func _apply_item_states(ui: CardUI, item: HandItemView) -> void:
	if item.pickable:
		ui.modulate = PICKABLE_TINT
	elif not item.affordable:
		ui.modulate = UNAFFORDABLE_DIM
	else:
		ui.modulate = Color.WHITE


# ── Selection (the hand's gesture on its own cards) ─────────────────────────────

# The pick, when it is one of this bar's cards.
func selected() -> CardUI:
	for ui: CardUI in _hand_cards:
		if Selection.holds(ui.subject()):
			return ui
	return null


# Nothing is picked any more. Only clears a pick that is actually a hand card's — a fielded
# unit's pick belongs to the board and is not the hand row's to clear.
func deselect() -> void:
	var ui := selected()
	if ui == null:
		return
	Sfx.play("card_deselect")
	Selection.clear()
	selection_changed.emit(null)


# The gesture on a hand card. Pressing the pick again means "never mind" — the one place a
# second press is not a no-op, because clearing is the only other thing this gesture can
# mean. Anything else is a single assignment; whatever was picked before stops being picked
# because it is no longer named, and its card works that out for itself.
func toggle_select(index: int) -> void:
	if not selection_enabled:
		return
	var ui := card_at(index)
	if ui == null:
		return
	if Selection.holds(ui.subject()):
		deselect()
		return
	Selection.select(ui.subject())
	Vfx.play("card_select_lift", ui)   # entry carries the select sound
	selection_changed.emit(ui)


# Placement input gating: outside the player's command span the hand presents but does not
# answer — and the play-me glow may only show while acting is possible at all.
func set_input_enabled(enabled: bool) -> void:
	selection_enabled = enabled
	for ui: CardUI in _hand_cards:
		ui.refresh_playable()


# ── The inspect sidebar + ability tray (injected — see HandInspectView) ─────────

# Injects what the sidebar and tray show: a fielded unit's read, or null to leave the
# inspect view. The HOST derives this from the one selection authority (the old bar derived
# it itself; the derivation moved to the engine-reading layer — the seam adaptation).
func set_inspect(view: HandInspectView) -> void:
	if view == _inspect:
		return
	_inspect = view
	if view != null:
		Sfx.play("card_inspect_open")
		_rebuild_inspect_view()
		_set_level(NavLevel.INSPECT)
		return
	clear_tokens()
	if _desc_preview != null:
		_desc_preview.queue_free()
		_desc_preview = null
	_desc_panel.visible = false
	if _nav_level == NavLevel.INSPECT:
		_set_level(NavLevel.HAND)


# Injects the Abilities level's roster (every fielded player unit bearing an ability); also
# gates the Inspect Abilities door.
func set_ability_roster(roster: Array[HandInspectView]) -> void:
	_roster = roster
	if _nav_level == NavLevel.ABILITIES:
		_rebuild_abilities_view()
	refresh_nav()


func _rebuild_inspect_view() -> void:
	clear_tokens()
	# Fresh preview each time (mirrors CardTooltip.build, which never reuses a CardUI across
	# different subjects either) — small, frame-and-art only, mouse-ignored like a portrait.
	if _desc_preview != null:
		_desc_preview.queue_free()
	_desc_preview = CardUI.create(_inspect.card, false)
	_desc_preview.custom_minimum_size = _card_size
	_desc_preview.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_desc_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_desc_hbox.add_child(_desc_preview)
	_desc_hbox.move_child(_desc_preview, 0)

	_desc_name_lbl.text = _inspect.title
	_desc_text_lbl.text = TextIcons.plain(_inspect.description)
	_fit_desc_width()
	var tray_size := _tray_card_size()
	for index: int in _inspect.ability_names.size():
		var token: Control
		var display: CardData = _inspect.ability_cards[index]
		if display != null:
			var widget := AbilityWidget.create_for(display)
			widget.custom_minimum_size = tray_size
			widget.draggable = false
			token = widget
		else:
			# No authored display card for this ability — a bare named plate (authoring the
			# AbilityData entry is the fix; visibly plain on purpose).
			var plate := Button.new()
			plate.text = String(_inspect.ability_names[index]).capitalize()
			plate.custom_minimum_size = tray_size
			token = plate
		token.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(token)
		row.add_child(_ability_text_col(_inspect.ability_texts[index], tray_size.y))
		_gen_cards.append(token)
		_gen_box.add_child(row)
		if _inspect.enemy:
			# An enemy roster is information only — look, don't touch.
			if token is CardUI:
				(token as CardUI).set_noninteractive()
			else:
				(token as Button).disabled = true
		else:
			# The tray IS the activation surface: a press asks the host to fire the ability.
			var ability_name: StringName = _inspect.ability_names[index]
			if token is CardUI:
				(token as CardUI).pressed.connect(
						func() -> void: ability_pressed.emit(ability_name))
			else:
				(token as Button).pressed.connect(
						func() -> void: ability_pressed.emit(ability_name))
	_hand_box.visible = false
	_gen_box.visible = not _gen_cards.is_empty()
	_no_abilities_lbl.visible = _gen_cards.is_empty()
	_desc_panel.visible = true


# Each ability's illustration sits beside a large-text description (the widget alone
# doesn't say what it does).
func _ability_text_col(text: String, col_h: float) -> Control:
	const COL_W := 280.0
	var clip := Control.new()
	clip.clip_contents = true
	clip.custom_minimum_size = Vector2(COL_W, col_h)
	clip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.text = TextIcons.plain(text)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", ABILITY_TEXT_COLOR)
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip.add_child(lbl)
	return clip


func clear_tokens() -> void:
	for token: Control in _gen_cards:
		if is_instance_valid(token):
			token.get_parent().queue_free()   # the row carries the token and its text column
	_gen_cards.clear()
	_gen_box.visible = false
	_no_abilities_lbl.visible = false
	if _nav_level == NavLevel.INSPECT:
		_hand_box.visible = true


# ── Hand-panel navigation (see NavLevel) ────────────────────────────────────────

func nav_level() -> NavLevel:
	return _nav_level


func show_abilities() -> void:
	Sfx.play("ability_tray_open")
	deselect()
	Selection.clear()
	_rebuild_abilities_view()
	# The sidebar doubles as the level's hint (no preview here — that's inspect-only).
	_desc_name_lbl.text = ""
	_desc_text_lbl.text = Loc.t("hand.click_to_inspect")
	_fit_desc_width()
	_set_level(NavLevel.ABILITIES)


# The universal back-out: NOTHING is picked — one write, whatever kind of pick was live.
# The panel derives itself shut; the explicit level set covers the one state with no pick
# to clear (the ABILITIES list, which is navigation, not selection).
func dismiss_to_hand() -> void:
	deselect()
	Selection.clear()
	_set_level(NavLevel.HAND)


func _on_back_to_hand() -> void:
	dismiss_to_hand()


# One switch for what each level shows: the three content rows swap in the same strip; the
# sidebar and token row are managed by the inspect enter/leave flows; the nav column's
# buttons are handed off to refresh_nav (a pure function of level + availability).
func _set_level(level: NavLevel) -> void:
	_nav_level = level
	_hand_box.visible      = level == NavLevel.HAND
	_abilities_box.visible = level == NavLevel.ABILITIES
	if level != NavLevel.INSPECT:
		_no_abilities_lbl.visible = false
	_desc_panel.visible    = level != NavLevel.HAND
	if level != NavLevel.ABILITIES:
		_clear_ability_entries()
	refresh_nav()


# Owns the nav column's button visibility — a pure function of the current level and the
# injected roster. (The old usable-right-now glow on the door needs per-ability payability
# composition — deferred, surfaced in the journal.)
func refresh_nav() -> void:
	if _inspect_abilities_btn == null:
		return
	_inspect_abilities_btn.visible = _nav_level == NavLevel.HAND and not _roster.is_empty()
	_back_btn.visible = _nav_level != NavLevel.HAND


func _rebuild_abilities_view() -> void:
	_clear_ability_entries()
	var entry_size := _tray_card_size()
	for entry: HandInspectView in _roster:
		var ui := CardUI.create(entry.card, false)
		ui.custom_minimum_size = entry_size
		ui.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ui.draggable = false   # a menu entry, not the board unit — click inspects, never drags
		var subject: Variant = entry.subject
		ui.pressed.connect(func() -> void: Selection.select(subject))
		_ability_entries.append(ui)
		_abilities_box.add_child(ui)


func _clear_ability_entries() -> void:
	for ui: CardUI in _ability_entries:
		if is_instance_valid(ui):
			ui.queue_free()
	_ability_entries.clear()


# THE HEADROOM RULE: the strip clips only when it has something to hide — a selected card
# grows OUT of the one-card-tall bar (the lifted read), but a full hand's overflow must
# scroll clipped or it draws over the mana column and the sidebar.
func _sync_strip_clip() -> void:
	if _scroll == null or _content == null:
		return
	_scroll.clip_contents = _content.size.x > _scroll.size.x + 1.0


# A card sized to sit FULLY on-screen in the hand strip — shrunk in from _card_size (kept
# to the card aspect) so its bottom clears the off-screen crop (BOTTOM_BLEED) instead of
# riding it like a hand card's dead frame.
func _tray_card_size() -> Vector2:
	var h := _card_size.y - 2.0 * BOTTOM_BLEED - 6.0
	return Vector2(roundf(h * _card_size.x / _card_size.y), roundf(h))


# Sizes the description column to the CURRENT text: as wide as the text wants on one line,
# capped so a long description wraps instead of ballooning the sidebar, floored so a
# one-word name still reads.
func _fit_desc_width() -> void:
	const MIN_W := 90.0
	var font := _desc_text_lbl.get_theme_default_font()
	var name_w: float = _desc_name_lbl.get_theme_default_font().get_string_size(
			_desc_name_lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, DESC_NAME_FONT).x
	var text_w: float = font.get_string_size(_desc_text_lbl.text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, DESC_FONT_MAX).x
	var w: float = clampf(maxf(name_w, text_w), MIN_W, DESC_MAX_W)
	_desc_clip.custom_minimum_size.x = w
	_fit_desc_font(w)


# Shrinks the description font a step at a time until the wrapped text fits the fixed box.
func _fit_desc_font(w: float) -> void:
	var font := _desc_text_lbl.get_theme_default_font()
	var box_h: float = _card_size.y - 20.0 - BOTTOM_BLEED - DESC_NAME_FONT - 12.0
	var size := DESC_FONT_MAX
	while size > DESC_FONT_MIN:
		var height: float = font.get_multiline_string_size(_desc_text_lbl.text,
				HORIZONTAL_ALIGNMENT_LEFT, w, size).y
		if height <= box_h:
			break
		size -= 2
	_desc_text_lbl.add_theme_font_size_override("font_size", size)


func view() -> HandView:
	return _view


func card_count() -> int:
	return _hand_cards.size()


func card_at(index: int) -> CardUI:
	if index < 0 or index >= _hand_cards.size():
		return null
	return _hand_cards[index]


# ── Sizing ───────────────────────────────────────────────────────────────────────

# Adopts the board's computed slot size as the hand's card size, resizing every presented
# card and the bar itself — a hand card and a fielded card are the same object, so they
# render at the same scale.
func set_card_size(s: Vector2) -> void:
	if s == _card_size:
		return
	_card_size = s
	if _panel != null:
		_panel.custom_minimum_size.y = s.y + PAD_TOP
	for ui: CardUI in _hand_cards:
		ui.custom_minimum_size = s
