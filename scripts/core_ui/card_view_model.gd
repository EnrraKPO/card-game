class_name CardViewModel
extends RefCounted

# The card concept's composer (docs/planning/RULINGS.html R6: card stands on its own): the
# one piece that reads the engine on CardUI's behalf, wherever the card renders — a fielded
# unit's face in a slot, a hand card, a drag ghost. It answers card questions only; slot
# questions live in SlotViewModel, status composition in StatusViewModel.


# A unit's card face: the live core stats bridged into the CardData shape CardUI renders.
# Rebuilt on every refresh — the face mirrors the world's current numbers, not the authored
# ones. The empty id keeps CardData's locale lookup silent; display_name carries the name.
# Composition stays empty for now: the core's card envelope carries no `elements` birth fact
# yet (its roster is id/name/stats/building/king/effects/abilities) — the face grows chips
# when the envelope grows the fact, with no change to CardUI.
static func unit_card(unit: Unit) -> CardData:
	var data := CardData.new()
	data.display_name = unit.display_name
	data.cost = roundi(unit.get_stat(&"cost"))
	data.attack = roundi(unit.get_stat(&"attack"))
	data.health = roundi(unit.get_stat(&"health"))
	data.speed = roundi(unit.get_stat(&"speed"))
	data.shield = roundi(unit.get_stat(&"shield"))
	data.is_king = unit.is_king
	data.card_type = CardData.CardType.UNIT
	return data


# The unit's held statuses as the card's badge-row views.
static func status_views(unit: Unit) -> Array[StatusPipView]:
	return StatusViewModel.held_views(unit)
