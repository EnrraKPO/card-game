class_name SlotGroundView
extends RefCounted

# The plain facts a slot's ground layer renders (docs/planning/RULINGS.html R4). The first
# status's identity leads the presentation — its color drives the frame, floor and occupant
# tint through GroundPalette, its id selects the ambient VFX by naming convention — and the
# pips row shows every status the ground carries.

var color: Color = Color.WHITE      # the leading status's own color
var status_id: String = ""          # the leading status's id (ambient VFX convention key)
var pips: Array[StatusPipView] = []
