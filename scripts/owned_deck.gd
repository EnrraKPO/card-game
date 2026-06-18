class_name OwnedDeck
extends RefCounted

# A player-OWNED deck: a first-class, editable, copyable entity living in the profile
# (ProfileData.decks). It references a King via `king_id` — the King is an ATTRIBUTE of
# the deck, not its identity — so the player may hold several decks for the same King and
# diverge each one. Decks are SEEDED from a King's template (the data/decks/*.json files,
# via DeckData) when a King is unlocked, but from then on they are independent copies.
#
# A run takes a deep-copied SNAPSHOT of the selected deck (snapshot_cards); run-time
# edits (forge charms, "?" upgrades) mutate that snapshot only, never the owned deck.

var id: String                  # unique instance id within the profile (e.g. "deck_3")
var name: String = ""           # player-facing label
var king_id: String = "king"    # the King this deck is played with
var cards: Array = []           # Array[DeckCard]


# Seeds a fresh owned deck from a King's template, falling back to the basic deck when
# that King has no deck file authored yet.
static func from_template(p_king_id: String, instance_id: String, display_name: String = "") -> OwnedDeck:
	var od := OwnedDeck.new()
	od.id = instance_id
	od.king_id = p_king_id
	od.name = display_name
	var ids: Array = DeckData.get_deck(p_king_id)
	if ids.is_empty():
		ids = DeckData.get_deck(DeckData.FALLBACK_ID)
	for card_id in ids:
		od.cards.append(DeckCard.make(card_id))
	return od


# A deep copy of the cards, safe to hand to a run (so run mutations don't leak back).
func snapshot_cards() -> Array:
	var out: Array = []
	for dc: DeckCard in cards:
		out.append(dc.clone())
	return out


# Duplicates this deck (deep-copied cards, same King) under a new instance id — the
# data-layer primitive behind a future "make a copy to edit" action.
func clone(new_id: String, new_name: String = "") -> OwnedDeck:
	var od := OwnedDeck.new()
	od.id = new_id
	od.king_id = king_id
	od.name = new_name if not new_name.is_empty() else name
	od.cards = snapshot_cards()
	return od


func to_dict() -> Dictionary:
	var card_data: Array = []
	for dc: DeckCard in cards:
		card_data.append(dc.to_dict())
	return {"id": id, "name": name, "king_id": king_id, "cards": card_data}


static func from_dict(data: Dictionary) -> OwnedDeck:
	var od := OwnedDeck.new()
	od.id = data.get("id", "")
	od.name = data.get("name", "")
	od.king_id = data.get("king_id", "king")
	for v in data.get("cards", []):
		od.cards.append(DeckCard.from_variant(v))
	return od
