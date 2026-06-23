class_name ForgeFX
extends RefCounted

# ── Forge particle tuning sheet ───────────────────────────────────────────────────────────────
# THE one place to tune the Forge drag VFX. ForgeAura (the halo that wraps each card) reads AURA;
# ForgeLink (the vortex that connects two cards) reads LINK; combination_screen reads a couple of
# layout values (margin / connect_intensity). Everything is a plain number so a future tuning tool
# can read/write this map directly. Per-mote values use min/max pairs (each mote rolls a random
# value in that range); _min == _max means "all motes identical".

const AURA := {
	# Field
	"count":             200,    # number of motes orbiting one card
	"margin":            0.0,    # px the ring sits OUTSIDE the card edge (0 = on the edge, <0 = inside)
	"path_exp":          0.55,   # path shape: 1.0 = ellipse, smaller = more rectangular (card-like)
	"connect_intensity": 2.2,    # intensity both halos ramp to while two cards are connected
	"intensity_ease":    5.0,    # how fast intensity eases toward its target (higher = snappier)

	# Per-mote dot
	"size_min":          0.2,    # dot radius in px (small = refined)
	"size_max":          0.6,
	"alpha_base":        0.65,   # opacity = base + amp*sin(flicker); clamped to [min,max]
	"alpha_amp":         0.15,
	"alpha_min":         0.35,
	"alpha_max":         0.80,
	"white_chance":      0.4,    # fraction of motes drawn pure white (rest take the card colour)

	# Orbit motion
	"spin_min":          0.7,    # angular speed (rad/s) magnitude
	"spin_max":          2.2,
	"counter_rotate":    0.25,   # fraction of motes that spin the opposite way (path crossing = tension)

	# Radius wobble (weave in/out of the path)
	"wobble_amp_min":    0.16,   # fraction of the radius a mote weaves
	"wobble_amp_max":    0.40,
	"wobble_freq_min":   1.8,    # weave speed
	"wobble_freq_max":   5.0,

	# Angular jitter (judder along the path)
	"ang_jitter_min":    0.04,   # radians
	"ang_jitter_max":    0.30,
	"ang_freq_min":      1.2,
	"ang_freq_max":      4.0,

	# Flicker
	"flick_min":         0.5,
	"flick_max":         1.2,
}

const CARD := {
	# The dragged card gently wobbles while it's connected to a target.
	"wobble_rot":  0.07,   # peak rotation in radians (~4°)
	"wobble_sway": 4.0,    # peak positional sway in px
	"wobble_freq": 9.0,    # wobble speed (rad/s)
	"wobble_ease": 10.0,   # how fast it eases in/out as the connection forms/breaks
}

const LINK := {
	# Motes leave a point on one card's orbit ring, arc across the gap, and merge onto the other
	# card's ring (fading in/out at the rings) — a seamless orbit-to-orbit transfer, never the centre.
	"count":        80,     # number of motes flowing between the two cards

	# Where on each ring motes enter/leave, and how curved the crossing is
	"spread":        1.3,    # radians of ring (each side of the facing point) motes fan across
	"bow":           0.18,   # arc curvature, as a fraction of the gap length (0 = straight)
	"end_fade":      0.22,   # fraction of the trip spent fading in (at source ring) / out (at sink ring)

	# Travel
	"speed_min":     0.5,    # crossing speed (trips/sec)
	"speed_max":     1.1,

	# Per-mote dot
	"size_min":      0.1,
	"size_max":      0.4,
	"alpha_base":    0.45,
	"alpha_amp":     0.15,
	"alpha_min":     0.15,
	"alpha_max":     0.60,
	"white_chance":  0.4,
	"flick_min":     0.5,
	"flick_max":     1.2,
}
