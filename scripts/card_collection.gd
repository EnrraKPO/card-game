class_name CardCollection
extends RefCounted

# Profile-scoped bag of crafted cards the player OWNS (card id -> count). Per the crafting/
# collection design: scarcity lives in the MATERIALS spent to mint a card (see Lab.mint);
# an owned card is then reusable across decks up to the owned count, with per-deck
# NON-COMPETING accounting (every deck may independently include up to `count` copies).
#
# NOT stored here: Kings (forged, not collected) and a King's innate template cards (those
# are free per-deck, capped at the template quantity — see DeckData.innate_count). Charmed /
# transmuted distinct entries are a later extension; for now this holds plain card ids only.

var _counts: Dictionary = {}


func count(id: String) -> int:
	return int(_counts.get(id, 0))


func add(id: String, n: int = 1) -> void:
	if n <= 0:
		return
	_counts[id] = count(id) + n


# Removes up to n copies (for a future Salvage verb); returns whether it removed any.
func remove(id: String, n: int = 1) -> bool:
	if n <= 0 or count(id) < n:
		return false
	var left := count(id) - n
	if left > 0:
		_counts[id] = left
	else:
		_counts.erase(id)
	return true


func ids() -> Array:
	return _counts.keys()


func is_empty() -> bool:
	return _counts.is_empty()


func to_dict() -> Dictionary:
	return _counts.duplicate()


static func from_dict(d: Dictionary) -> CardCollection:
	var c := CardCollection.new()
	for id: String in d:
		c._counts[id] = int(d[id])
	return c
