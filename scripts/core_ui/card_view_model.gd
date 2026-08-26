class_name CardViewModel
extends RefCounted

# The card concept's composer (docs/planning/RULINGS.html R6: card stands on its own): the
# one piece that reads the engine on CardUI's behalf, wherever the card renders — a fielded
# unit's face in a slot, a hand card, a drag ghost. It answers card questions only; slot
# questions live in SlotViewModel, status composition in StatusViewModel.


# A unit's card face: the live core stats bridged into the CardData shape CardUI renders.
# Rebuilt on every refresh — the face mirrors the world's current numbers, not the authored
# ones. The face's presentation identity comes from the authored seat (_authored_face):
# with the catalogue converted, a core entity's id names its catalogue card, whose art,
# locale identity, and chess pieces dress the face; composition elements come from the
# core's `elements` birth fact (A7). An id with no catalogue seat (the slice's working
# labels) renders bare, display_name carrying the name.
static func unit_card(unit: Unit) -> CardData:
	var data := _authored_face(unit)
	data.cost = roundi(unit.get_stat(&"cost"))
	data.attack = roundi(unit.get_stat(&"attack"))
	data.health = roundi(unit.get_stat(&"health"))
	data.speed = roundi(unit.get_stat(&"speed"))
	data.shield = roundi(unit.get_stat(&"shield"))
	data.is_king = unit.is_king
	data.card_type = CardData.CardType.UNIT
	return data


# A fresh CardData carrying the presentation identity — never the registry's own object
# (the face takes live stat overrides; the registry must keep the authored numbers).
static func _authored_face(card: Card) -> CardData:
	var data := CardData.new()
	data.display_name = card.display_name
	for element: StringName in card.elements:
		data.elements.append(String(element))
	# A variant envelope — a run-modified or power-scaled card fielded under
	# "{base}~{n}" (RunFight, B40) — wears its base card's authored seat.
	var authored: CardData = CardData.get_card(String(card.id).get_slice("~", 0))
	if authored != null:
		data.id = authored.id
		data.art_path = authored.art_path
		data.chess_pieces = authored.chess_pieces.duplicate()
	return data


# The unit's held statuses as the card's badge-row views.
static func status_views(unit: Unit) -> Array[StatusPipView]:
	return StatusViewModel.held_views(unit)


# Any card's face — the kind decides the shape: a unit brings its combat stats, a spell
# carries only its name and cost (CardUI hides the stat badges off the SPELL type).
static func card_face(card: Card) -> CardData:
	if card is Unit:
		return unit_card(card as Unit)
	var data := _authored_face(card)
	data.cost = roundi(card.get_stat(&"cost"))
	data.card_type = CardData.CardType.SPELL
	return data
