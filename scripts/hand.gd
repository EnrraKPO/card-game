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

const INITIAL_DRAW := 4

# Wires a spell CardUI for drag-casting; injected by combat (SpellCaster.wire_spell_card).
var wire_spell_card: Callable
# Card selection is only honoured while the orchestrator has placement input enabled
# (i.e. during the player's placement phase). Toggled via set_input_enabled().
var selection_enabled: bool = false

var _draw_pile: Array  = []  # Array[CardInstance]
var _hand_cards: Array = []  # Array[CardUI]
var _gen_cards: Array  = []  # Array[CardUI] — rook-generated tokens, this turn only
var _selected: CardUI  = null

var _hand_box: BoxContainer
var _gen_box: BoxContainer
var _gen_separator: Control


# ── UI construction ──────────────────────────────────────────────────────────────

func build_into(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 235.0
	parent.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	# The hand row holds normal cards on the left, then a separator and the
	# rook-generated "build" tokens on the right so they read as distinct.
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)

	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 12)
	content.add_child(_hand_box)

	_gen_separator = VSeparator.new()
	_gen_separator.visible = false
	content.add_child(_gen_separator)

	_gen_box = HBoxContainer.new()
	_gen_box.add_theme_constant_override("separation", 12)
	_gen_box.visible = false
	content.add_child(_gen_box)


# ── Draw pile + drawing ──────────────────────────────────────────────────────────

func populate_draw_pile(deck_ids: Array) -> void:
	var ids := deck_ids.duplicate()
	ids.shuffle()
	for id in ids:
		var data := CardData.get_card(id)
		if data and not data.is_king:
			var inst := CardInstance.from_data(data)
			inst.owner = 0
			_draw_pile.append(inst)


func draw_initial() -> void:
	var n := mini(INITIAL_DRAW, _draw_pile.size())
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


# ── Rook / building tokens ───────────────────────────────────────────────────────

# Offers one token per player building, each linked to its source rook. Tokens are
# use-it-or-lose-it: rebuilt fresh every round. Buildings whose composition yields no
# token (plain/double rook) are skipped — see CardData.generated_card().
func generate_tokens(buildings: Array) -> void:
	clear_tokens()
	for building: CardInstance in buildings:
		var base := building.data.generated_card()
		if base == null:
			continue
		var tok := CardInstance.from_data(base)
		tok.owner = 0
		tok.row = -1
		tok.col = -1
		tok.source_building = building
		var ui := CardUI.create(tok, true)
		_gen_cards.append(ui)
		_gen_box.add_child(ui)   # entering the tree runs _ready, so set_generated is safe after
		ui.set_generated()
		ui.pressed.connect(func(): _toggle_select(ui))
		ui.mouse_entered.connect(func(): token_hovered.emit(building, true))
		ui.mouse_exited.connect(func():  token_hovered.emit(building, false))
	var has_tokens := not _gen_cards.is_empty()
	_gen_box.visible = has_tokens
	_gen_separator.visible = has_tokens


func clear_tokens() -> void:
	for ui: CardUI in _gen_cards:
		if ui.card_instance != null:
			token_hovered.emit(ui.card_instance.source_building, false)
		ui.queue_free()
	_gen_cards.clear()
	_gen_box.visible = false
	_gen_separator.visible = false


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
		_gen_separator.visible = false


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
