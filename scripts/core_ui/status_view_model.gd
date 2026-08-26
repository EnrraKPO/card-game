class_name StatusViewModel
extends RefCounted

# The status concept's composer (docs/planning/RULINGS.html R4/R6): one core Status becomes
# one StatusPipView, wherever the status is held — a slot's ground and a unit's card row both
# ask here, so "the ground has a status" and "a unit has one" stay one presentation language.
# Display metadata the core doesn't carry (colour, icon, glyph, aura) is bridged from the
# authored StatusData registry by id; an unregistered status renders bare rather than
# refusing — authoring the entry is the whole fix.


# The count decision lives HERE, not in the pip: the core's statuses carry intensity as the
# `stacks` stat, so stacks headline the badge and the separate "x N" tag stays off.
static func pip_view(status: Status) -> StatusPipView:
	var view := StatusPipView.new()
	view.id = String(status.status_id)
	view.subject = status
	view.stacks = maxi(roundi(status.get_stat(&"stacks")), 1)
	view.count = view.stacks
	view.show_stacks = false
	view.display_name = view.id.capitalize()
	var authored := StatusData.get_status(view.id)
	if authored != null:
		view.display_name = authored.display_name
		view.color = authored.color
		view.icon = authored.icon()
		view.glyph = authored.glyph
		view.duplicates = authored.stack_display == "duplicates"
		view.aura = authored.aura
		view.description = authored.description
	return view


# Every Status housed in `holder`'s own `contained` container, as pip views in holding
# order. A spent status (stacks at zero — Poison decayed out) shows no pip: removal is
# out of frame (Mutation §14), so the entity stays; the view is where "spent" reads.
static func held_views(holder: GameEntity) -> Array[StatusPipView]:
	var views: Array[StatusPipView] = []
	for member: GameEntity in holder.get_container(&"contained").members:
		var status := member as Status
		if status != null and status.get_stat(&"stacks") > 0.0:
			views.append(pip_view(status))
	return views
