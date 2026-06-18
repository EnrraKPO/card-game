class_name Materials
extends RefCounted

# Display + lookup helpers for profile crafting resources (the meta economy). Lightweight
# seed of a future MaterialData registry — for now names derive from the element cards and
# colours live here. Materials are an id→count bag on ProfileData; ids are element ids
# ("fire".."light") for essences and "king_piece" for King Pieces.

const ELEMENTS := ["fire", "water", "air", "earth", "darkness", "light"]

const ELEMENT_COLOR := {
	"fire":     Color(0.90, 0.35, 0.20),
	"water":    Color(0.30, 0.55, 0.95),
	"air":      Color(0.70, 0.85, 0.95),
	"earth":    Color(0.55, 0.75, 0.35),
	"darkness": Color(0.60, 0.40, 0.80),
	"light":    Color(0.95, 0.90, 0.50),
}


# Full label, e.g. "Fire Essence" / "King Piece" — used by the hub and reward screen.
static func display_name(id: String) -> String:
	if id == "king_piece":
		return "King Piece"
	var card := CardData.get_card(id)
	if card != null and not card.elements.is_empty():
		return "%s Essence" % card.display_name
	return id.capitalize()


# Short label, e.g. "Fire" — used in compact map-node previews.
static func short_name(id: String) -> String:
	if id == "king_piece":
		return "King Piece"
	var card := CardData.get_card(id)
	return card.display_name if card != null else id.capitalize()


static func color(id: String) -> Color:
	return ELEMENT_COLOR.get(id, Color.WHITE)


# Compact "+2 Fire" summary of a rewards dict (id→count) for map previews.
static func summary(rewards: Dictionary) -> String:
	var parts: Array = []
	for id: String in rewards:
		parts.append("+%d %s" % [int(rewards[id]), short_name(id)])
	return ", ".join(parts)
