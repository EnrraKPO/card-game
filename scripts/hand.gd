class_name Hand
extends Node

# Owns the player's hand: the draw pile, the normal hand cards, the rook-generated
# tokens, the containers that present them, and the current selection. Cross-cutting
# concerns (mana, board placement, which board slot a token highlights) stay in the
# combat orchestrator — this node only manages hand state + presentation and reports
# intent back through signals and a small query interface.

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
# Card selection is only honoured while the orchestrator has placement input enabled
# (i.e. during the player's placement phase). Toggled via set_input_enabled().
var selection_enabled: bool = false

var _draw_pile: Array  = []  # Array[CardInstance]
var _hand_cards: Array = []  # Array[CardUI]
var _gen_cards: Array  = []  # Array[CardUI] — rook-generated tokens, this turn only
var _selected: CardUI  = null
var _inspected: CardInstance = null

var _hand_box: BoxContainer
var _gen_box: BoxContainer
var _desc_panel: PanelContainer
var _back_btn: Button
var _desc_hbox: HBoxContainer
var _desc_name_lbl: Label
var _desc_text_lbl: Label
var _desc_preview: CardUI = null

# Card preview shown in the sidebar's description panel, sized to fill the full hand-bar
# height (235) at the card's native 260:340 aspect ratio — AT LEAST the game's regular card
# size (160×210, see card_ui.tscn), not a shrunk-down "card inside a card". This is the
# panel's whole focus; there's no reason for it to be smaller than an ordinary card.
const DESC_PREVIEW_SIZE := Vector2(180, 235)


# ── UI construction ──────────────────────────────────────────────────────────────

func build_into(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 235.0
	parent.add_child(panel)

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

	# Padding inside the hand bar so the first/last card isn't jammed against the screen edge and
	# the row breathes off the top/bottom of the bar. The scroll (and its cards) live inside this.
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 28)
	pad.add_theme_constant_override("margin_right", 28)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_bottom", 12)
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

	var desc_vbox := VBoxContainer.new()
	desc_vbox.custom_minimum_size.x = 260.0   # wide enough that the description rarely wraps
	# past 2-3 lines — a too-narrow column was forcing enough wrap to blow past the fixed
	# panel height and squash the rest of the sidebar.
	desc_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL   # top-aligned, matching the
	# preview's own top alignment below — SHRINK_CENTER here (short text, tall box) floated the
	# whole column in the middle with dead space above/below it, reading as "shrunk".
	desc_vbox.add_theme_constant_override("separation", 12)
	_desc_hbox.add_child(desc_vbox)

	_desc_name_lbl = Label.new()
	_desc_name_lbl.add_theme_font_size_override("font_size", 24)
	desc_vbox.add_child(_desc_name_lbl)

	_desc_text_lbl = Label.new()
	_desc_text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_text_lbl.add_theme_font_size_override("font_size", 18)
	_desc_text_lbl.add_theme_color_override("font_color", Color("3a2f22"))
	_desc_text_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_vbox.add_child(_desc_text_lbl)

	# "Back to hand" is its own block at the far right of the sidebar — not a small button sharing
	# a row with the name label. THE shared chrome button (ScreenUI.action_button) — CHROME_NEUTRAL
	# is the app's standing color for Back/secondary actions. A genuine inset margin on all four
	# sides (explicitly asked for), NOT a shrink-to-minimum-and-center — the button still fills
	# whatever's left inside that margin, so it stays big.
	var back_wrap := MarginContainer.new()
	back_wrap.add_theme_constant_override("margin_left", 16)
	back_wrap.add_theme_constant_override("margin_right", 16)
	back_wrap.add_theme_constant_override("margin_top", 16)
	back_wrap.add_theme_constant_override("margin_bottom", 16)
	back_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_hbox.add_child(back_wrap)

	_back_btn = ScreenUI.action_button("← Back to hand", clear_inspected, Vector2(220, 64), 24,
			ScreenUI.CHROME_NEUTRAL)
	_back_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_back_btn.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	back_wrap.add_child(_back_btn)

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


# ── Draw pile + drawing ──────────────────────────────────────────────────────────

func populate_draw_pile(deck_cards: Array) -> void:
	var cards := deck_cards.duplicate()
	cards.shuffle()
	for dc: DeckCard in cards:
		var inst := dc.make_instance()
		if inst != null and not inst.data.is_king:
			inst.owner = 0
			# Fill to the run-resolved max (read-time card modifiers add to max_health once
			# owner is set), so a fresh unit enters at full HP including any unit.health buff.
			Resolver.fill_health(inst)
			_draw_pile.append(inst)


func draw_initial() -> void:
	var n := mini(GameData.value("hand.size.initial"), _draw_pile.size())
	for i in n:
		_spawn_hand_card(_draw_pile[i])
	_draw_pile = _draw_pile.slice(n)


func draw_one() -> void:
	if _draw_pile.is_empty():
		return
	_spawn_hand_card(_draw_pile[0])
	_draw_pile = _draw_pile.slice(1)


func _spawn_hand_card(inst: CardInstance) -> void:
	inst.row = -1
	inst.col = -1
	var ui := CardUI.create(inst, true)
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


# ── Card inspection (description + activated abilities) ───────────────────────────

# Clicking any board unit (either side) makes it "inspected": the hand row swaps to show
# the unit's full description plus its abilities as card-shaped entries, one at a time.
# Enemy units are inspectable too, for information — see _rebuild_inspect_view for the
# interactive-vs-view-only split.
func set_inspected(inst: CardInstance) -> void:
	_inspected = inst
	_rebuild_inspect_view()
	inspect_changed.emit(inst)


# Leaves the inspect view and restores the normal hand row.
func clear_inspected() -> void:
	if _inspected == null:
		return
	_inspected = null
	clear_tokens()
	if _desc_preview != null:
		_desc_preview.queue_free()
		_desc_preview = null
	_desc_panel.visible = false
	_hand_box.visible = true
	inspect_changed.emit(null)


func inspected() -> CardInstance:
	return _inspected


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
		if ab.tap and inst.attack_exhausted:
			continue
		var tok := CardInstance.from_data(ab.display_card())
		tok.owner = inst.owner
		tok.row = -1
		tok.col = -1
		tok.source_building = inst
		tok.ability = ab
		var ui := AbilityWidget.create_for(tok)
		_gen_cards.append(ui)
		_gen_box.add_child(ui)   # entering the tree runs _ready, so set_generated is safe after
		ui.set_generated()
		if interactive:
			if wire_spell_card.is_valid():
				wire_spell_card.call(ui)
			ui.autocast_toggled.connect(_on_autocast_toggled)
			ui.mouse_entered.connect(func(): token_hovered.emit(inst, true))
			ui.mouse_exited.connect(func():  token_hovered.emit(inst, false))
		else:
			ui.set_noninteractive()
	_hand_box.visible = false
	_gen_box.visible = true
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
