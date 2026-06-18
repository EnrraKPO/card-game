class_name ProfileData
extends RefCounted

# Profile-scoped meta-progression that outlives any single run — a sibling to
# RunData/MapState, but persisted ONCE per profile (a "profile" save section), not
# per run slot. A new run draws its deck from the selected OwnedDeck here, and permanent
# unlocks accumulate here across runs. Surfaced by the "game world" hub
# (game_world.gd). This is the load-bearing layer for the roguelike meta loop;
# content panels (king select, deck editing, unlock shop) build on top of it.
#
# Decks are first-class OWNED entities (see OwnedDeck), not derived from the King:
# unlocking a King seeds a deck from its template, but the player may then hold several
# decks per King and edit each. "Picking a deck" picks its King (king_id is deck metadata).

const STARTING_KING := "king"

var unlocked_kings: Array = []   # Array[String]: king card ids the player may run with
var decks: Array = []            # Array[OwnedDeck]: the player's owned, editable decks
var selected_deck_id: String = ""  # which OwnedDeck a fresh run uses
var next_deck_uid: int = 0       # monotonic counter for collision-free OwnedDeck ids
var renown: int = 0              # meta-currency earned from runs, spent on permanent unlocks


static func create_default() -> ProfileData:
	var p := ProfileData.new()
	p.unlocked_kings = [STARTING_KING]
	p.renown = 0
	var deck := p._seed_deck(STARTING_KING)
	p.selected_deck_id = deck.id
	return p


static func from_dict(data: Dictionary) -> ProfileData:
	if data.is_empty():
		return create_default()
	var p := ProfileData.new()
	p.unlocked_kings = data.get("unlocked_kings", [STARTING_KING])
	p.renown = int(data.get("renown", 0))
	p.next_deck_uid = int(data.get("next_deck_uid", 0))
	if data.has("decks"):
		for d in data.get("decks", []):
			p.decks.append(OwnedDeck.from_dict(d))
		p.selected_deck_id = data.get("selected_deck_id", "")
	else:
		# Migrate a pre-owned-deck save: one deck seeded from the legacy selected_king,
		# preserving a legacy `starting_deck` (card-id list) if one was stored.
		var king: String = data.get("selected_king", STARTING_KING)
		var deck := p._seed_deck(king)
		var legacy_cards: Array = data.get("starting_deck", [])
		if not legacy_cards.is_empty():
			deck.cards.clear()
			for v in legacy_cards:
				deck.cards.append(DeckCard.from_variant(v))
		p.selected_deck_id = deck.id
	# Guard against a dangling/empty selection.
	if p.get_selected_deck() == null:
		var fallback := p._seed_deck(STARTING_KING)
		p.selected_deck_id = fallback.id
	return p


func to_dict() -> Dictionary:
	var deck_data: Array = []
	for od: OwnedDeck in decks:
		deck_data.append(od.to_dict())
	return {
		"unlocked_kings":   unlocked_kings,
		"decks":            deck_data,
		"selected_deck_id": selected_deck_id,
		"next_deck_uid":    next_deck_uid,
		"renown":           renown,
	}


# ── Deck / King access ────────────────────────────────────────────────────────────

# The owned deck a fresh run will use. Falls back to the first owned deck if the stored
# selection is missing; null only if the player somehow owns no decks at all.
func get_selected_deck() -> OwnedDeck:
	for od: OwnedDeck in decks:
		if od.id == selected_deck_id:
			return od
	return decks[0] if not decks.is_empty() else null


# Convenience for the many call sites that only need the King of the active deck.
func get_selected_king() -> String:
	var od := get_selected_deck()
	return od.king_id if od != null else STARTING_KING


# Unlocks a King (if new) and grants a fresh deck seeded from its template — the
# data-layer entry point for the future unlock shop.
func unlock_king(king_id: String) -> OwnedDeck:
	if king_id not in unlocked_kings:
		unlocked_kings.append(king_id)
	return _seed_deck(king_id)


# ── internals ─────────────────────────────────────────────────────────────────────

# Creates, registers, and returns a new owned deck from a King's template.
func _seed_deck(king_id: String) -> OwnedDeck:
	var deck := OwnedDeck.from_template(king_id, _new_deck_id())
	decks.append(deck)
	return deck


func _new_deck_id() -> String:
	var deck_id := "deck_%d" % next_deck_uid
	next_deck_uid += 1
	return deck_id
