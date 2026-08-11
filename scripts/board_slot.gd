class_name BoardSlot
extends GameEntity

# One cell of the GROUND layer: a filing cabinet whose identity IS its address. The board is a
# stack of layers over one shared coordinate space — ground (slots, permanent) under pieces
# (units, transient) — and co-location is INCIDENTAL: a unit is "on top of" its slot, never
# inside it. See SLOT_LAYER_DESIGN.md.
#
# A SLOT IS AN ORDINARY DOCKABLE, not a special case (LOCATION_MANAGER_DESIGN.md §2.4). Its
# identity is its location and it never undocks — but that is a property of the slot, not a
# rule the manager knows, and the manager is exactly as ignorant of what a slot is as it is of
# what a unit is.
#
# IT DOES NOT STORE ITS OWN ADDRESS. That was the last coordinate store outside the manager:
# ask the world (BoardFacade.location_of) and you get an answer that cannot be stale, on a
# board that cannot be the wrong one. A slot stores only what it is the authority on — the
# statuses filed on it.
#
# The location's `side` is SPATIAL addressing (which half's coordinate space the cell lives
# in), NOT the allegiance of anything the slot does — allegiance is answered per-dispatch
# through the context's owner_anchor (see CombatCascade's ground pass).


func dock_layer() -> StringName:
	return BoardFacade.GROUND
