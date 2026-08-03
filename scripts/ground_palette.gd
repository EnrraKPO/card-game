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
#   • FRAME — the PALEST, and a thin rail rather than a broad band. It lives in the gutter, outside
#     every card silhouette, so it is the one part never covered and it still has to carry the state
#     when a card hides everything else — but it must not compete with the tabs riding on it. Pale
#     against their vivid is what separates them now that the tab has no border of its own. (It is
#     deliberately not DARKENED: the board's zone is dark, and a dark band on a dark board is the
#     read we already tried and lost.)
#   • FLOOR — the faintest, a wash over the slot's own dark surface. It is mostly hidden under an
#     occupant and is not asked to carry anything; it exists so the slot's INTERIOR belongs to the
#     status too, rather than the state stopping at a border.
#   • TAB — the most VIVID, because it is the only surface drawn ON another one (over the frame, in
#     the shared top gutter). It carries the whole separation on its own: the tab has no border (a
#     black outline read as grime against the fire — user's call), so nothing but the shade itself
#     tells the marker apart from the band it sits on.


# Nearly opaque: the frame is the state's spine, not an accent.
const FRAME_ALPHA := 0.92
# ⚠ LIGHTER, NOT WHITER. `lightened()` blends toward white, which drains the hue out — the frame
# came out chalky pink and stopped reading as fire at all (user's call, and the same trap the tab
# fell into one revision earlier). Lifting VALUE while keeping most of the saturation gives a
# lighter flame instead of a washed one: the frame is the pale outer tongue, the tab the hot core.
# Barely eased at all: the frame covers a LOT of pixels, and desaturation that looks mild on a swatch
# reads as salmon across a whole board. Lightness here comes almost entirely from value.
const FRAME_SAT := 0.85   # multiplier on saturation — eased off, never abandoned
const FRAME_VAL := 1.15   # ...and on value; both clamp at full
# A wash, not a wall — the same lesson the old over-the-card tint learned the hard way. Measured
# against a floor-off reference, never eyeballed: warm card art reads as tinted when it isn't.
const FLOOR_ALPHA := 0.30
# ⚠ SATURATION, not paleness. `lightened()` was the first answer here and it is the wrong one: it
# blends toward WHITE, so the tab separated from the frame by going washed-out — a chalky salmon
# sitting on a vivid orange band, reading as a faded version of the status rather than a hotter one.
# Pushing saturation and value instead keeps the hue exactly where the status put it and separates
# by INTENSITY, which is also the right story: the marker is the fire at its brightest.
const TAB_SAT := 1.35   # multiplier on the status colour's saturation
const TAB_VAL := 1.12   # ...and on its value; both clamp at full
# The tab's outline: the status colour in SHADOW. Deep enough to cut the tab out of the frame it
# sits on, but never the near-black the card badge wears — black is a UI device and reads as grime
# on a fire, where a burnt-orange edge reads as the same flame with the light behind it.
const TAB_BORDER_VAL := 0.42   # multiplier on value; saturation is held, so it stays a fire colour


static func frame(c: Color) -> Color:
	var lit := Color.from_hsv(c.h, minf(c.s * FRAME_SAT, 1.0), minf(c.v * FRAME_VAL, 1.0), c.a)
	return Color(lit, FRAME_ALPHA)


static func floor_wash(c: Color) -> Color:
	return Color(c, FLOOR_ALPHA)


static func tab(c: Color) -> Color:
	return Color.from_hsv(c.h, minf(c.s * TAB_SAT, 1.0), minf(c.v * TAB_VAL, 1.0), c.a)


# The colour the ground MULTIPLIES over whatever stands in it — its light on the occupant, not a
# surface of its own. Lerped from white toward the status so the strength is one readable number:
# white is a no-op under multiply, so 0 = untouched and 1 = the card fully in the status's colour.
# Multiply rather than an alpha wash because multiply keeps the art's own luminance — the unit is
# still lit and shaded as painted, just lit by a fire — where a wash flattens it toward one tone.
const OCCUPANT_TINT := 0.45


static func on_occupant(c: Color) -> Color:
	return Color.WHITE.lerp(c, OCCUPANT_TINT)


static func tab_border(c: Color) -> Color:
	return Color.from_hsv(c.h, minf(c.s * TAB_SAT, 1.0), c.v * TAB_BORDER_VAL, c.a)
