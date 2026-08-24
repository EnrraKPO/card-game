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
# answer a pick with it) — the bar only reports where the finger landed.
signal card_pressed(index: int)

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
	_pad.add_child(_scroll)

	# SHRINK_CENTER vertically so every card sits on the same centreline.
	_content = HBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	_content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scroll.add_child(_content)

	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 12)
	_hand_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_hand_box)


# ── The one input ────────────────────────────────────────────────────────────────

# Injects the hand's whole presentation and re-renders the row. The card views are rebuilt
# per injection — the row is small, and reconciliation earns its keep only when the draw/
# discard animations return (their own atom).
func set_hand(view: HandView) -> void:
	_view = view
	for ui: CardUI in _hand_cards:
		if is_instance_valid(ui):
			_hand_box.remove_child(ui)
			ui.queue_free()
	_hand_cards.clear()
	if _view == null:
		return
	for index: int in _view.items.size():
		var item: HandItemView = _view.items[index]
		var ui := CardUI.create(item.card, true)
		ui.custom_minimum_size = _card_size
		ui.set_status_views(item.statuses)
		_apply_item_states(ui, item)
		ui.pressed.connect(func() -> void: card_pressed.emit(index))
		_hand_cards.append(ui)
		_hand_box.add_child(ui)


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
