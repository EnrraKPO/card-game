class_name GroundPalette
extends RefCounted

# ── The ground layer's shades, derived from a status's ONE authored colour ─────────────────────
#
# A ground status paints three surfaces at once (SlotUI's frame and floor, StatusPip's tabs), and
# they overlap: the tabs ride the top gutter, which is exactly where the frame runs. Three parts of
# one system in ONE flat colour would read as a single smeared shape, so each surface takes its own
# shade of the same hue — same status, three depths.
#
# Derived, never authored per surface: a status declares `color` and nothing else, so a new ground
# status is a colour and an icon, with no presentation to fill in. That also keeps the three shades
# in a fixed RELATIONSHIP — retuning one here retunes every ground status at once.
#
# The relationship, and why it is this way round:
#   • FRAME — the loud read, at nearly full strength. It lives in the gutter, outside every card
#     silhouette, so it is the ONE part that is never covered; it has to carry the state alone when
#     a big card hides everything else. (It is deliberately NOT the darkest: the board's zone is
#     dark, and a darkened band on a dark board is the read we already tried and lost.)
#   • FLOOR — the faintest, a wash over the slot's own dark surface. It is mostly hidden under an
#     occupant and is not asked to carry anything; it exists so the slot's INTERIOR belongs to the
#     status too, rather than the state stopping at a border.
#   • TAB — the brightest, because it is the only surface drawn ON another one (over the frame, in
#     the shared top gutter). Lifting it toward white is what separates a marker pinned to the band
#     from a bulge in the band. Its own dark border (StatusPip._tab_style) does the rest.


# Nearly opaque: the frame is the state's spine, not an accent.
const FRAME_ALPHA := 0.92
# A wash, not a wall — the same lesson the old over-the-card tint learned the hard way. Measured
# against a floor-off reference, never eyeballed: warm card art reads as tinted when it isn't.
const FLOOR_ALPHA := 0.30
# Toward white — but only far enough to separate. Lifting a colour desaturates it, and a tab pale
# enough to read as a different HUE stops looking like the same status as the band it sits on.
const TAB_LIFT := 0.26


static func frame(c: Color) -> Color:
	return Color(c, FRAME_ALPHA)


static func floor_wash(c: Color) -> Color:
	return Color(c, FLOOR_ALPHA)


static func tab(c: Color) -> Color:
	return c.lightened(TAB_LIFT)
