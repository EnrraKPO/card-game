class_name DeckUI
extends RefCounted

# Shared visuals for the deck screens (management + run-select), so both illustrate a deck
# with its King's actual card the same way.

const CARD_RATIO := 340.0 / 260.0   # CardUI native height / width (see CardUI.NATIVE_SIZE)


# A fixed-size thumbnail of a King's card (the real CardUI, scaled to `width`).
# `interactive` keeps the CardUI live so hovering shows its detail tooltip and clicking
# emits its `pressed` signal; otherwise it's decorative (mouse passes through so a parent
# button stays clickable). CardUI's scene sets a 160x210 minimum, so we MUST override it to
# the thumbnail size or the card is floored at full size and spills over its neighbours.
static func king_thumbnail(king_id: String, width: float, interactive := false) -> Control:
	var card_size := Vector2(width, width * CARD_RATIO)
	var data := CardData.get_card(king_id)
	if data == null:
		var placeholder := Control.new()
		placeholder.custom_minimum_size = card_size
		return placeholder
	var ui := CardUI.create(CardInstance.from_data(data))
	ui.draggable = false
	ui.custom_minimum_size = card_size
	if not interactive:
		ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ui


# The display label for a deck: the King's name, with a " (n)" suffix for a King's 2nd+ deck.
static func deck_label(od: OwnedDeck, ordinal: int) -> String:
	var king := CardData.get_card(od.king_id)
	var label := king.display_name if king != null else od.king_id
	if ordinal > 1:
		label += " (%d)" % ordinal
	return label


# A read-only grid of a deck's cards (each the real CardUI, baked with its overrides/charms
# via DeckCard.make_instance). Shared by the Decks preview pane and the View Deck screen.
static func deck_grid(od: OwnedDeck, columns: int, card_width: float) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	var card_size := Vector2(card_width, card_width * CARD_RATIO)
	for dc: DeckCard in od.cards:
		var inst := dc.make_instance()
		if inst == null:
			continue
		var ui := CardUI.create(inst)
		ui.draggable = false
		ui.custom_minimum_size = card_size
		grid.add_child(ui)
	return grid
