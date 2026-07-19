class_name ForgeCosts
extends RefCounted

# The Magic Mineral price of a forge merge — the one place the cost formula lives, so the
# side panel, the confirm modal and the commit (_do_combine) can never disagree. All four
# knobs are GameAttributes (Tool ▸ 🎛 Tuning ▸ 👑 Game attributes) and resolve through
# GameData.value, so upgrades/relics can modify them like any other number.
#
# cost = result pieces × per_piece + result elements × per_element + ONE flat:
#   • element_only — both inputs are pure-element cards (no chess piece anywhere), or
#   • piece_op     — at least one input holds a chess piece component.
# Component counts come from the RESULT card's composition (the merge sums its parents',
# so this scales with what's being built). Charm enchants are free — merges only.


# The current knob values (id → int), resolved through the registry.
static func knobs() -> Dictionary:
	return {
		"per_piece":    GameData.value("forge.cost.per_piece"),
		"per_element":  GameData.value("forge.cost.per_element"),
		"element_only": GameData.value("forge.cost.element_only"),
		"piece_op":     GameData.value("forge.cost.piece_op"),
	}


# The mineral cost of merging `a` + `b`. Callers pass only valid pairs (CardData.can_combine);
# `k` overrides the knob dict (the regression suite injects fixed values — see knobs()).
static func merge_cost(a: CardData, b: CardData, k: Dictionary = {}) -> int:
	if k.is_empty():
		k = knobs()
	var result := CardData.combine(a, b)
	var element_only := a.chess_pieces.is_empty() and b.chess_pieces.is_empty()
	var flat: int = int(k["element_only"]) if element_only else int(k["piece_op"])
	return maxi(0, result.chess_pieces.size() * int(k["per_piece"])
			+ result.elements.size() * int(k["per_element"]) + flat)
