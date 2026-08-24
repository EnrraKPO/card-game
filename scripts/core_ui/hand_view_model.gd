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
		item.subject = card
		item.card = CardViewModel.card_face(card)
		if card is Unit:
			item.statuses = CardViewModel.status_views(card as Unit)
		item.affordable = card.payable()
		item.pickable = pick_candidates.has(card)
		view.items.append(item)
	return view


# The inspect read for one fielded unit: its face and text, plus one entry per borne
# ability. Display metadata comes from the authored AbilityData registry by name; an
# ability the registry doesn't know renders as its bare name (authoring the entry is the
# fix) — the core's envelope carries no ability display data of its own.
static func inspect_view(unit: Unit, player_side: Side) -> HandInspectView:
	var view := HandInspectView.new()
	view.subject = unit
	view.title = unit.display_name
	view.card = CardViewModel.unit_card(unit)
	view.enemy = unit.allegiance != player_side
	for ability_name: StringName in unit.abilities:
		view.ability_names.append(ability_name)
		var authored: AbilityData = AbilityData.get_ability(String(ability_name))
		if authored != null:
			view.ability_cards.append(authored.display_card())
			var text := authored.display_name
			if not authored.description.is_empty():
				text += "\n" + authored.description
			view.ability_texts.append(text)
		else:
			view.ability_cards.append(null)
			view.ability_texts.append(String(ability_name).capitalize())
	return view


# The Abilities level's roster: every fielded player unit that bears at least one ability.
static func ability_roster(world: World) -> Array[HandInspectView]:
	var roster: Array[HandInspectView] = []
	var player: Side = world.player_side()
	for row: int in BoardGeometry.ROWS:
		for col: int in BoardGeometry.COLS:
			var unit: Unit = SlotViewModel.occupant(
					world.board_manager.slot_at(Vector3i(0, row, col)))
			if unit != null and not unit.abilities.is_empty():
				roster.append(inspect_view(unit, player))
	return roster
