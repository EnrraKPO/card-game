class_name HandViewModel
extends RefCounted

# The hand concept's composer (docs/planning/RULINGS.html R7/R8): reads the engine on the
# hand bar's behalf and builds the HandView it renders. Card faces come through
# CardViewModel (the card concept unchanged); the hand-relational states land on each
# HandItemView wrapper. `pick_candidates` is the live pick's candidate list (empty outside
# a pick) — interaction state the SCREEN holds, passed in rather than read, so this
# composer stays a pure function of its inputs.


static func hand_view(side: Side, pick_candidates: Array[GameEntity] = []) -> HandView:
	var view := HandView.new()
	for member: GameEntity in side.get_container(&"hand").members:
		var card := member as Card
		if card == null:
			continue
		var item := HandItemView.new()
		item.card = CardViewModel.card_face(card)
		if card is Unit:
			item.statuses = CardViewModel.status_views(card as Unit)
		item.affordable = card.payable()
		item.pickable = pick_candidates.has(card)
		view.items.append(item)
	return view
