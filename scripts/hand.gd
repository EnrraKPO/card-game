class_name Hand
extends Node

# PRESENTS the player's hand: the hand-card UI, the rook-generated tokens, the containers
# that present them, and the current selection. Hand STATE (the card instances + draw pile)
# lives on the player's CombatSide — this node subscribes to its signals (see bind_side)
# and mirrors them as CardUI. Cross-cutting concerns (mana, board placement, which board
# slot a token highlights) stay in the combat orchestrator; intent reports back through
# signals and a small query interface.

# Emitted when a generated token is hovered/unhovered so the orchestrator can glow
# the source building's board slot. Also emitted (with `false`) when a token is
# cleared, so any lingering highlight is dropped.
signal token_hovered(building: CardInstance, hovering: bool)

# Emitted whenever the inspected card changes (including to null on clear) so the
# orchestrator can mirror it as a board highlight — see Combat._on_inspect_changed.
signal inspect_changed(inst: CardInstance)

# Emitted when an ability widget's autocast toggle changes a holder's armed state, so the
# orchestrator can refresh that unit's board card (the armed-brackets echo).
signal autocast_changed(holder: CardInstance)

# Wires a spell CardUI for drag-casting; injected by combat (SpellCaster.wire_spell_card).
var wire_spell_card: Callable
# The fielded player units that HAVE at least one activated ability, payable RIGHT NOW or not
# (func() -> Array[CardInstance]); injected by combat — feeds the level-2 Abilities view and the
# Inspect Abilities button's visibility.
var get_ability_units: Callable
# Whether a specific ability is castable this instant by its holder (func(holder, ab) -> bool:
# tap not spent AND mana affordable); injected by combat. Splits "has the ability" from "can pay
# for it" — drives the tray's spent-token grey and the Inspect Abilities button's usable-glow.
var is_ability_usable: Callable
# Card selection is only honoured while the orchestrator has placement input enabled
# (i.e. during the player's placement phase). Toggled via set_input_enabled().
var selection_enabled: bool = false

# The hand panel's navigation levels: the plain hand row, the Abilities list (fielded units
# with an offerable ability, an activation menu), and the single-unit inspection view. One
# always-visible button column drives them (see _set_level); the panel's height never changes.
enum NavLevel { HAND, ABILITIES, INSPECT }

var _hand_cards: Array = []  # Array[CardUI]
var _gen_cards: Array  = []  # Array[CardUI] — rook-generated tokens, this turn only
var _ability_entries: Array = []  # Array[CardUI] — the level-2 Abilities view's entries
var _selected: CardUI  = null
var _inspected: CardInstance = null
var _nav_level: NavLevel = NavLevel.HAND

var _card_size: Vector2 = CARD_SIZE   # current card footprint — see set_card_size

var _panel: PanelContainer
var _hand_box: BoxContainer
var _gen_box: BoxContainer
var _abilities_box: BoxContainer
var _no_abilities_lbl: Label
var _desc_panel: PanelContainer
var _back_btn: Button
var _inspect_abilities_btn: GlossyButton
var _desc_hbox: HBoxContainer
var _desc_name_lbl: Label
var _desc_text_lbl: Label
var _desc_preview: CardUI = null

# Pre-layout default for every card presented in the hand bar (hand cards, ability tokens,
# the Abilities-list entries). The REAL size arrives via set_card_size: combat mirrors its
# computed board-slot size here, so a card is the same object at the same scale whether it's
# in the hand or on the field — one card size for the whole screen.
const CARD_SIZE := Vector2(220, 288)

# How far the hand bar deliberately hangs BELOW the screen's bottom edge (combat pulls its
# body margin down by this much). The cropped band is dead card frame: the lowest stat gem
# (the speed badge) ends at ~96% of the card's height — 288×4% ≈ 11.5px of empty border —
# so 8 crops only frame while leaving the gems a few px of visible clearance.
const BOTTOM_BLEED := 8.0

# The bar's one vertical pad, above the cards (none below — see build_into). Public because it's
# a term in combat's shared-card-size solve (_resize_board): bar height = card height + this.
const PAD_TOP := 6.0

# The Inspect Abilities button's base colour — fuchsia, deliberately loud (see its build site).
const INSPECT_ACCENT := Color("d92bc4")

# Card preview shown in the sidebar's description panel, sized to fill the full hand-bar
# height at the card's native 260:340 aspect ratio — AT LEAST the game's regular card
# size (160×210, see card_ui.tscn), not a shrunk-down "card inside a card". This is the
# panel's whole focus; there's no reason for it to be smaller than an ordinary card.
const DESC_PREVIEW_SIZE := Vector2(205, 268)


# ── UI construction ──────────────────────────────────────────────────────────────

# `left_widget` (optional) is mounted as the bar's LEFTMOST column, spanning the full bar
# height — combat hands its mana gauge in here, since mana is what the hand spends.
func build_into(parent: Control, left_widget: Control = null) -> void:
	_panel = PanelContainer.new()
	# Card height + the top pad only — the cards sit flush at the bar's bottom, whose last
	# BOTTOM_BLEED px hang off-screen (see the consts above).
	_panel.custom_minimum_size.y = _card_size.y + PAD_TOP
	parent.add_child(_panel)
	var panel := _panel

	# Top-level row: the card area (padded, see below) and the inspect sidebar are SIBLINGS
	# here, not nested — the sidebar must NOT inherit the card area's padding. That padding
	# exists so CARDS aren't jammed against the screen edge; the sidebar is a solid panel, not
	# a card, and has no such reason to be inset from the bar's own edges. It spans the full
	# 235px bar height, flush top/bottom/right.
	var outer_row := HBoxContainer.new()
	outer_row.add_theme_constant_override("separation", 16)
	outer_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_row.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	panel.add_child(outer_row)

	if left_widget != null:
		outer_row.add_child(left_widget)

	# Padding inside the hand bar: the row breathes off the top of the bar, and the last card
	# keeps clear of the sidebar. NO left padding — the mana gauge column (plus the row's own
	# separation) already stands between the first card and the screen edge, so more inset there
	# is dead space. NO bottom padding: the cards sit flush at the bar's bottom edge so the
	# off-screen bleed (BOTTOM_BLEED) crops only their dead sub-gem frame, not empty panel. The
	# scroll (and its cards) live inside this.
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 0)
	pad.add_theme_constant_override("margin_right", 20)
	pad.add_theme_constant_override("margin_top", int(PAD_TOP))
	pad.add_theme_constant_override("margin_bottom", 0)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	outer_row.add_child(pad)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	pad.add_child(scroll)

	# The inspect sidebar: one panel, hidden entirely outside inspection (see
	# set_inspected/clear_inspected). Flush to the bar's own edges — no corner rounding (nothing
	# needs it), no internal padding (nothing inside is smaller than its allotted space, so
	# there's nothing to protect from clipping), full 235px height.
	_desc_panel = PanelContainer.new()
	_desc_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_panel.visible = false
	# Light SURFACE_DEEP background, same as CardTooltip — the dark description text below
	# (matching CardTooltip's own color) is illegible against the hand bar's dark theme without
	# it. Color contrast alone delineates the panel, so no border and no rounding are needed.
	var desc_style := StyleBoxFlat.new()
	desc_style.bg_color = ScreenUI.SURFACE_DEEP
	desc_style.set_content_margin_all(0)
	_desc_panel.add_theme_stylebox_override("panel", desc_style)
	outer_row.add_child(_desc_panel)

	_desc_hbox = HBoxContainer.new()
	_desc_hbox.add_theme_constant_override("separation", 14)
	_desc_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_panel.add_child(_desc_hbox)
	# The preview CardUI (art + frame) is inserted as _desc_hbox's first child fresh on every
	# _rebuild_inspect_view call — see there for why it's rebuilt rather than reused in place.

	# A modest inset around the text column: at INSPECT the preview card used to be the only
	# thing keeping the name off the panel edge, and at ABILITIES (no preview — the sidebar
	# shows the level hint) the text sat flush against the panel's left edge.
	var desc_text_wrap := MarginContainer.new()
	desc_text_wrap.add_theme_constant_override("margin_left", 14)
	desc_text_wrap.add_theme_constant_override("margin_top", 10)
	desc_text_wrap.add_theme_constant_override("margin_right", 10)
	# The panel's last BOTTOM_BLEED px are off-screen — keep the text's clearance above that.
	desc_text_wrap.add_theme_constant_override("margin_bottom", 10 + int(BOTTOM_BLEED))
	desc_text_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_text_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_hbox.add_child(desc_text_wrap)

	var desc_vbox := VBoxContainer.new()
	desc_vbox.custom_minimum_size.x = 260.0   # wide enough that the description rarely wraps
	# past 2-3 lines — a too-narrow column was forcing enough wrap to blow past the fixed
	# panel height and squash the rest of the sidebar.
	desc_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL   # top-aligned, matching the
	# preview's own top alignment below — SHRINK_CENTER here (short text, tall box) floated the
	# whole column in the middle with dead space above/below it, reading as "shrunk".
	desc_vbox.add_theme_constant_override("separation", 12)
	desc_text_wrap.add_child(desc_vbox)

	_desc_name_lbl = Label.new()
	_desc_name_lbl.add_theme_font_size_override("font_size", 24)
	desc_vbox.add_child(_desc_name_lbl)

	_desc_text_lbl = Label.new()
	_desc_text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_text_lbl.add_theme_font_size_override("font_size", 18)
	_desc_text_lbl.add_theme_color_override("font_color", Color("3a2f22"))
	_desc_text_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_vbox.add_child(_desc_text_lbl)

	# The navigation button column at the far right of the bar — ALWAYS visible (unlike the
	# sidebar), one column for every level so the actions live in the same place throughout.
	# THE shared chrome buttons (ScreenUI.action_button / GlossyButton) — CHROME_NEUTRAL is the
	# app's standing color for Back/secondary actions. A genuine inset margin on all four sides
	# (explicitly asked for), NOT a shrink-to-minimum-and-center — the visible buttons still
	# fill whatever's left inside that margin, SHARING the column height evenly when more than
	# one shows (all EXPAND_FILL children of one VBox), so they stay big.
	var nav_wrap := MarginContainer.new()
	nav_wrap.add_theme_constant_override("margin_left", 16)
	nav_wrap.add_theme_constant_override("margin_right", 16)
	nav_wrap.add_theme_constant_override("margin_top", 16)
	# The buttons are interactable, so they must clear the off-screen bleed band entirely.
	nav_wrap.add_theme_constant_override("margin_bottom", 16 + int(BOTTOM_BLEED))
	nav_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_row.add_child(nav_wrap)

	# Every size in this column is chosen so its GlossyButton bake never COMPRESSES (a nine-patch
	# only stretches cleanly; squeezing the centre band doubles the baked rim into seams):
	# the full-band Inspect button rides the short-portrait bake (170×280, ratio ≤ 0.68), and
	# the Back pills ride the 48 bucket (136 wide) — every width stays at/above its bake's.
	# No alignment override: every child is EXPAND_FILL, so there's nothing to center — the
	# visible buttons split the column height between them, and a lone survivor takes it all.
	var nav_box := VBoxContainer.new()
	nav_box.add_theme_constant_override("separation", 10)
	nav_wrap.add_child(nav_box)

	# The door to the Abilities list — a TALL, narrow button spanning the whole hand band (it's
	# the hand bar's landmark), its label wrapping to two lines so it doesn't hoard width.
	# Fuchsia: a deliberately loud accent — the gateway to abilities must not read as chrome.
	# NOT a per-level button: it's offered wherever the Abilities list is meaningful (the plain
	# hand AND the single-card inspect view), gated purely on there being abilities to inspect —
	# see refresh_nav. EXPAND_FILL so it (or Back to hand) claims the whole column when alone.
	_inspect_abilities_btn = ScreenUI.action_button("Inspect Abilities", show_abilities,
			Vector2(140, 64), 22, INSPECT_ACCENT)
	_inspect_abilities_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspect_abilities_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	nav_box.add_child(_inspect_abilities_btn)

	# Straight back to the plain hand, from either raised level (routed through _on_back_to_hand
	# so it also covers Abilities, where nothing is inspected). EXPAND_FILL, same as the button
	# above: when only one of the two shows, it fills the column — never a half-height button.
	_back_btn = ScreenUI.action_button("← Back to hand", _on_back_to_hand, Vector2(140, 56), 18,
			ScreenUI.CHROME_NEUTRAL)
	_back_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_back_btn.visible = false
	nav_box.add_child(_back_btn)

	# The hand row and the ability-token row occupy the same space and are shown one at a time
	# (see set_inspected/clear_inspected) — never both visible together. Both SHRINK_CENTER
	# vertically so every card sits on the same centreline.
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	scroll.add_child(content)

	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 12)
	_hand_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	content.add_child(_hand_box)

	_gen_box = HBoxContainer.new()
	_gen_box.add_theme_constant_override("separation", 12)
	_gen_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gen_box.visible = false
	content.add_child(_gen_box)

	# Shown in the token row's place when the inspected unit offers no activated abilities,
	# so the inspect view says why that space is empty instead of just being empty.
	_no_abilities_lbl = Label.new()
	_no_abilities_lbl.text = "This unit doesn't have activated abilities"
	_no_abilities_lbl.add_theme_font_size_override("font_size", 20)
	_no_abilities_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	# Card-height box with centred text: a bare label's own height won't centre inside the
	# ScrollContainer (cards only look centred because they fill the row), so the label
	# claims the same height a card row does and centres its text within it.
	_no_abilities_lbl.custom_minimum_size.y = _card_size.y
	_no_abilities_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_no_abilities_lbl.visible = false
	content.add_child(_no_abilities_lbl)

	# The level-2 Abilities row — same slot in the content strip as the other two, shown one
	# at a time (see _set_level).
	_abilities_box = HBoxContainer.new()
	_abilities_box.add_theme_constant_override("separation", 12)
	_abilities_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_abilities_box.visible = false
	content.add_child(_abilities_box)


# ── State mirroring (the player's CombatSide drives; this bar presents) ──────────

# Subscribes this bar to the player side's zone signals: drawn cards spawn CardUI,
# discarded cards drop theirs. All draw/discard STATE changes happen on the side (via
# the Resolver); this is the one place the hand UI learns about them.
func bind_side(side: CombatSide) -> void:
	side.cards_drawn.connect(_on_cards_drawn)
	side.cards_discarded.connect(_on_cards_discarded)


func _on_cards_drawn(insts: Array) -> void:
	if not insts.is_empty():
		Sfx.play("card_draw")   # once per burst — a turn's multi-draw is one deal, not a drumroll
	for inst: CardInstance in insts:
		_spawn_hand_card(inst)


func _on_cards_discarded(insts: Array) -> void:
	for ui: CardUI in _hand_cards.duplicate():
		if insts.has(ui.card_instance):
			remove_card(ui)
			ui.queue_free()


func _spawn_hand_card(inst: CardInstance) -> void:
	inst.row = -1
	inst.col = -1
	var ui := CardUI.create(inst, true)
	ui.custom_minimum_size = _card_size
	_hand_cards.append(ui)
	_hand_box.add_child(ui)
	if ui.card_instance.is_spell:
		if wire_spell_card.is_valid():
			wire_spell_card.call(ui)
	else:
		ui.pressed.connect(func(): _toggle_select(ui))


func refresh() -> void:
	for ui: CardUI in _hand_cards:
		ui.refresh()


# Adopts the board's computed slot size as the hand's card size (combat calls this from
# _resize_board), resizing every presented card and the bar itself — a hand card and a fielded
# card are the same object, so they render at the same scale. Changing the bar's height re-fires
# combat's resize, but that solve reads only inputs this bar can't affect, so the second pass
# lands on the identical size and stops there (see _resize_board — this invariant is what keeps
# the two from resize-looping each other).
func set_card_size(s: Vector2) -> void:
	if s == _card_size:
		return
	_card_size = s
	if _panel != null:
		_panel.custom_minimum_size.y = s.y + PAD_TOP
	if _no_abilities_lbl != null:
		_no_abilities_lbl.custom_minimum_size.y = s.y
	for ui: CardUI in _hand_cards:
		ui.custom_minimum_size = s
	for ui: CardUI in _gen_cards:
		ui.custom_minimum_size = s
	for ui: CardUI in _ability_entries:
		ui.custom_minimum_size = s


# ── Card inspection (description + activated abilities) ───────────────────────────

# Clicking any board unit (either side) makes it "inspected": the hand row swaps to show
# the unit's full description plus its abilities as card-shaped entries, one at a time.
# Enemy units are inspectable too, for information — see _rebuild_inspect_view for the
# interactive-vs-view-only split.
func set_inspected(inst: CardInstance) -> void:
	_inspected = inst
	_rebuild_inspect_view()
	_set_level(NavLevel.INSPECT)
	inspect_changed.emit(inst)


# Leaves the inspect view and restores the normal hand row (level 1) — the "Back to hand"
# action, unchanged; "Back to Abilities" tears down the same state but lands on level 2.
func clear_inspected() -> void:
	if _inspected == null:
		return
	_leave_inspect()
	_set_level(NavLevel.HAND)


# Tears down the inspection state (tokens, preview, sidebar) without deciding where the
# navigation lands — the two Back actions differ only in the level they return to.
func _leave_inspect() -> void:
	if _inspected == null:
		return
	_inspected = null
	clear_tokens()
	if _desc_preview != null:
		_desc_preview.queue_free()
		_desc_preview = null
	_desc_panel.visible = false
	inspect_changed.emit(null)


func inspected() -> CardInstance:
	return _inspected


# Re-derives the inspect view's ability tray against the holder's CURRENT offerability —
# called by combat after an ability is spent so a tapped-out unit's tray drops to the
# "no activated abilities" state IN PLACE, without popping out of the inspect view (a
# non-tap ability's token simply reappears, still castable). A no-op outside inspection.
func refresh_inspect() -> void:
	if _inspected == null:
		return
	_rebuild_inspect_view()


# ── Hand-panel navigation (see NavLevel) ───────────────────────────────────────────

func nav_level() -> NavLevel:
	return _nav_level


# Whether a screen-space point lands on the hand panel — the outside-click dismissal's
# boundary (see Combat._input).
func panel_contains(point: Vector2) -> bool:
	return _panel != null and _panel.get_global_rect().has_point(point)


# Level 2: the Abilities list — every fielded player unit with a currently OFFERABLE ability
# (same availability rule as the amber board cue: a tapped unit's tap-costed abilities don't
# count), as clickable entries that drill into the unit's inspection.
func show_abilities() -> void:
	deselect()
	_leave_inspect()   # reachable from level 3 ("Back to Abilities") — drop that state first
	_rebuild_abilities_view()
	# The sidebar doubles as the level's hint (no preview here — that's inspect-only).
	_desc_name_lbl.text = ""
	_desc_text_lbl.text = "Click a unit to inspect its abilities."
	_set_level(NavLevel.ABILITIES)


# The outside-click dismissal (see Combat._unhandled_input): any level, straight back to the
# plain hand row, clearing the inspected card on the way.
func dismiss_to_hand() -> void:
	if _inspected != null:
		clear_inspected()
	else:
		_set_level(NavLevel.HAND)


func _on_back_to_hand() -> void:
	dismiss_to_hand()


# One switch for what each level shows: the three content rows swap in the same strip, the
# sidebar (_desc_panel) and token row are managed by the inspect enter/leave flows, and the
# nav column's buttons are handed off to refresh_nav (a pure function of level + availability).
func _set_level(level: NavLevel) -> void:
	_nav_level = level
	_hand_box.visible      = level == NavLevel.HAND
	_abilities_box.visible = level == NavLevel.ABILITIES
	if level != NavLevel.INSPECT:
		_no_abilities_lbl.visible = false
	# The sidebar serves both raised levels: the unit detail at INSPECT (filled by
	# _rebuild_inspect_view), the "click a unit" hint at ABILITIES (set by show_abilities).
	_desc_panel.visible    = level != NavLevel.HAND
	if level != NavLevel.ABILITIES:
		_clear_ability_entries()
	refresh_nav()


# Owns the nav column's button visibility — a pure function of the current level and whether
# any fielded unit still has an offerable ability. Called on every level change AND whenever
# ability availability shifts under a stationary level: prune_tapped here, plus board changes
# from combat (unit placed, turn-start untap — combat calls this). So Inspect Abilities
# appears/vanishes in lockstep with there being abilities to inspect. Both buttons are
# EXPAND_FILL, so whichever shows alone claims the whole column — never a half-height button.
func refresh_nav() -> void:
	if _inspect_abilities_btn == null:   # wired to mana_changed, which can fire before the bar builds
		return
	var has_abilities: bool = get_ability_units.is_valid() and not get_ability_units.call().is_empty()
	# Glow when at least one of those abilities is castable RIGHT NOW — the button stays visible
	# whether or not anything's payable (units still have abilities worth inspecting), but the
	# pulse only invites a click when there's actually something to do this moment.
	var has_usable := false
	if has_abilities and is_ability_usable.is_valid():
		for inst: CardInstance in get_ability_units.call():
			for ab: AbilityData in inst.ability_list():
				if is_ability_usable.call(inst, ab):
					has_usable = true
					break
			if has_usable:
				break
	# Inspect Abilities: the door to the Abilities list, offered wherever it's meaningful — the
	# plain hand and the single-card inspect view — but never on the Abilities list itself, and
	# only while some unit actually has an ability to inspect.
	_inspect_abilities_btn.visible = _nav_level != NavLevel.ABILITIES and has_abilities
	_inspect_abilities_btn.set_glow(_inspect_abilities_btn.visible and has_usable)
	_back_btn.visible              = _nav_level != NavLevel.HAND


func _rebuild_abilities_view() -> void:
	_clear_ability_entries()
	if not get_ability_units.is_valid():
		return
	for inst: CardInstance in get_ability_units.call():
		var ui := CardUI.create(inst, false)
		ui.custom_minimum_size = _card_size
		ui.draggable = false   # a menu entry, not the board unit — click inspects, never drags
		ui.pressed.connect(func(): set_inspected(inst))
		# Hovering an entry glows its board slot, same affordance as hovering an ability token.
		ui.mouse_entered.connect(func(): token_hovered.emit(inst, true))
		ui.mouse_exited.connect(func():  token_hovered.emit(inst, false))
		_ability_entries.append(ui)
		_abilities_box.add_child(ui)


func _clear_ability_entries() -> void:
	for ui: CardUI in _ability_entries:
		if ui.card_instance != null:
			token_hovered.emit(ui.card_instance, false)
		ui.queue_free()
	_ability_entries.clear()


# One entry per ability; a tap-costed ability of an already-tapped holder isn't offered at
# all. Abilities of the player's own units are real, castable spell-shaped activations
# (routed through SpellCaster like any hand spell); an inspected ENEMY unit's abilities are
# shown the same way for information but rendered non-interactive — look, don't touch.
func _rebuild_inspect_view() -> void:
	clear_tokens()
	var inst := _inspected

	# Fresh preview each time (mirrors CardTooltip.build, which never reuses a CardUI across
	# different CardInstances either) — small, frame-and-art only, mouse-ignored like a portrait.
	if _desc_preview != null:
		_desc_preview.queue_free()
	_desc_preview = CardUI.create(inst, false)
	_desc_preview.custom_minimum_size = DESC_PREVIEW_SIZE
	_desc_preview.size_flags_vertical = Control.SIZE_SHRINK_BEGIN   # top-aligned with the text
	# column beside it (see desc_vbox) — SHRINK_CENTER paired with a shorter text block created
	# mismatched empty bands above/below both, reading as "shrunk into the middle".
	_desc_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_desc_hbox.add_child(_desc_preview)
	_desc_hbox.move_child(_desc_preview, 0)

	_desc_name_lbl.text = inst.data.display_name
	_desc_text_lbl.text = inst.data.description
	var interactive := inst.owner == 0
	for ab: AbilityData in inst.ability_list():
		var tok := CardInstance.from_data(ab.display_card())
		tok.owner = inst.owner
		tok.row = -1
		tok.col = -1
		tok.source_building = inst
		tok.ability = ab
		var ui := AbilityWidget.create_for(tok)
		ui.custom_minimum_size = _card_size
		_gen_cards.append(ui)
		_gen_box.add_child(ui)   # entering the tree runs _ready, so set_generated is safe after
		ui.set_generated()
		if not interactive:
			ui.set_noninteractive()
			continue
		# The unit's whole ability roster is shown, payable or not. A currently-unpayable one
		# (tapped out or unaffordable) rides the same spent grey as a tapped board unit and can't
		# be drag-cast — but it still arms (right-click) and hovers, since arming survives tapping.
		if is_ability_usable.is_valid() and is_ability_usable.call(inst, ab):
			if wire_spell_card.is_valid():
				wire_spell_card.call(ui)
		else:
			ui.draggable = false
			ui.set_exhausted(true)
		ui.autocast_toggled.connect(_on_autocast_toggled)
		ui.mouse_entered.connect(func(): token_hovered.emit(inst, true))
		ui.mouse_exited.connect(func():  token_hovered.emit(inst, false))
	_hand_box.visible = false
	_gen_box.visible = not _gen_cards.is_empty()
	_no_abilities_lbl.visible = _gen_cards.is_empty()
	_desc_panel.visible = true


# Arming one ability implicitly disarms the holder's other one (single autocast_ability
# field) — refresh EVERY tray widget so the disarmed sibling's brackets dim too, then let
# the orchestrator update the holder's board card.
func _on_autocast_toggled(holder: CardInstance) -> void:
	for ui: CardUI in _gen_cards:
		ui.refresh()
	autocast_changed.emit(holder)


# Removes remaining tray offers a holder can no longer pay for because it just tapped —
# a tapped shopkeeper's tap-costed wares leave the shelf immediately.
func prune_tapped(holder: CardInstance) -> void:
	for ui: CardUI in _gen_cards.duplicate():
		var inst := ui.card_instance
		if inst != null and inst.source_building == holder \
				and inst.ability != null and inst.ability.tap:
			remove_token(ui)
			token_hovered.emit(holder, false)
			ui.queue_free()
	# The holder just tapped out, so the roster of ability-bearing units may have shrunk (to
	# empty). Re-derive the Inspect Abilities button so it withdraws the moment nothing's left —
	# this fires under a stationary level too (e.g. an autocast fired from the plain hand).
	refresh_nav()


func clear_tokens() -> void:
	for ui: CardUI in _gen_cards:
		if ui.card_instance != null:
			token_hovered.emit(ui.card_instance.source_building, false)
		ui.queue_free()
	_gen_cards.clear()
	_gen_box.visible = false


# ── Removing played cards (UI already reparented/freed by the caller) ─────────────

func remove_card(ui: CardUI) -> void:
	_hand_cards.erase(ui)
	if _selected == ui:
		_selected = null


# Removes a played token from the hand's bookkeeping and hides the token zone once
# empty. The orchestrator handles the source-rook side effects (exhaust + dim).
func remove_token(ui: CardUI) -> void:
	_gen_cards.erase(ui)
	if _selected == ui:
		_selected = null
	if _gen_cards.is_empty():
		_gen_box.visible = false


# ── Selection ────────────────────────────────────────────────────────────────────

func selected() -> CardUI:
	return _selected


func deselect() -> void:
	if _selected != null:
		_selected.set_selected(false)
		_selected = null


func _toggle_select(ui: CardUI) -> void:
	if not selection_enabled:
		return
	if _selected == ui:
		deselect()
	else:
		deselect()
		_selected = ui
		ui.set_selected(true)


# ── Queries + input gating ───────────────────────────────────────────────────────

# Generated tokens are played like hand cards (normal mana cost), so they count as
# "from hand" for the board's placement/mana checks too.
func contains(ui: CardUI) -> bool:
	return _hand_cards.has(ui) or _gen_cards.has(ui)


func set_input_enabled(enabled: bool) -> void:
	selection_enabled = enabled
	var filter := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for ui: CardUI in _hand_cards:
		ui.mouse_filter = filter
	for ui: CardUI in _gen_cards:
		ui.mouse_filter = filter
