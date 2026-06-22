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
	"count":             160,    # number of motes orbiting one card
	"margin":            0.0,    # px the ring sits OUTSIDE the card edge (0 = on the edge, <0 = inside)
	"path_exp":          0.55,   # path shape: 1.0 = ellipse, smaller = more rectangular (card-like)
	"connect_intensity": 2.2,    # intensity both halos ramp to while two cards are connected
	"intensity_ease":    8.0,    # how fast intensity eases toward its target (higher = snappier)

	# Per-mote dot
	"size_min":          0.8,    # dot radius in px (small = refined)
	"size_max":          1.8,
	"alpha_base":        0.85,   # opacity = base + amp*sin(flicker); clamped to [min,max]
	"alpha_amp":         0.15,
	"alpha_min":         0.65,
	"alpha_max":         1.0,
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
	"count":          80,     # number of motes in the vortex between two cards

	# Width of the funnel
	"width_factor":   0.5,    # width = gap_distance * this ...
	"width_min":      12.0,   # ... clamped so close cards don't smear into a cross ...
	"width_max":      160.0,  # ... and far cards don't get absurd
	"converge_pow":   1.0,    # how the funnel narrows into the sink card (1 = linear taper)

	# Travel + swirl
	"speed_min":      0.5,    # travel speed (cycles/sec) source -> sink
	"speed_max":      1.1,
	"amp_min":        0.35,   # fraction of width a mote swings off-axis
	"amp_max":        1.1,
	"twist_min":      1.0,    # how many times a mote crosses the axis en route
	"twist_max":      2.6,

	# Per-mote dot
	"size_min":       0.8,
	"size_max":       1.8,
	"alpha_base":     0.85,
	"alpha_amp":      0.15,
	"alpha_min":      0.55,
	"alpha_max":      1.0,
	"white_chance":   0.4,
	"flick_min":      0.5,
	"flick_max":      1.2,
}
