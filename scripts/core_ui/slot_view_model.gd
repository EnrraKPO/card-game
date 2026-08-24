class_name SlotViewModel
extends RefCounted

# The slot concept's composer (docs/planning/RULINGS.html R4/R6): the one piece that reads
# the engine on SlotUI's behalf, answering SLOT questions only — who stands here, what
# ground is claimed here. The occupant's own face is the card concept's business
# (CardViewModel); status composition is StatusViewModel's.


static func occupant(slot: Slot) -> Unit:
	if slot == null:
		return null
	var members: Array[GameEntity] = slot.get_container(&"slotted_unit").members
	return members[0] as Unit if not members.is_empty() else null


# The slot's ground, as the widget renders it: every Status housed in the slot's own
# `contained` container becomes one pip view, and the first leads the presentation.
static func ground_view(slot: Slot) -> SlotGroundView:
	if slot == null:
		return null
	var pips: Array[StatusPipView] = StatusViewModel.held_views(slot)
	if pips.is_empty():
		return null
	var view := SlotGroundView.new()
	view.color = pips[0].color
	view.status_id = pips[0].id
	view.pips = pips
	return view
