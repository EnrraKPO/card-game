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
	"count":             80,    # number of motes orbiting one card
	"radius_scale":      0.8,    # ⟵ ring radius handle: multiplies the card half-size (1 = on the edge, 1.2 = 20% wider, 0.8 = tighter)
	"margin":            0.0,    # flat px nudge added AFTER the scale (0 = none, <0 = inward)
	"path_exp":          0.55,   # path shape: 1.0 = ellipse, smaller = more rectangular (card-like)
	"connect_intensity": 2.2,    # intensity both halos ramp to while two cards are connected
	"intensity_ease":    5.0,    # how fast intensity eases toward its target (higher = snappier)

	# Pulsing glow — a soft additive bloom that fills the card and breathes, but ONLY while linked.
	# It's keyed off intensity rising above idle (1.0), so it fades in/out with the connection and
	# shows on both cards at once. Set glow_alpha to 0 to disable.
	"glow_mix":          0.45,   # how far the card colour blends toward white for the bloom tint
	"glow_layers":       6,      # stacked superellipse fills (more = smoother falloff)
	"glow_reach":        0.6,    # how far past the card edge the outer bloom reaches (fraction of radius)
	"glow_alpha":        0.06,   # per-layer base opacity (additive — layers stack toward the centre)
	"glow_pulse_amp":    0.55,   # pulse depth (fraction the glow dims at the trough)
	"glow_pulse_freq":   5.0,    # pulse speed (rad/s) — ~0.8 Hz breathing

	# Per-mote dot
	"size_min":          0.2,    # dot radius in px (small = refined)
	"size_max":          1.5,
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
	# Two reacting cards wobble while connected — the SAME motion everywhere it happens: a dragged
	# card over its target, and the queued pair in the combine modal / forge side panel.
	"wobble_rot":     0.045,  # peak tilt in radians (~2.5°) — a small quiver, not a big swing
	"wobble_freq":    9.0,    # wobble speed (rad/s)
	"wobble_ease":    10.0,   # how fast it eases in/out as the connection forms/breaks
	# On top of the tilt, each card lunges toward its partner so the two read as PULLING together.
	"pull_frac":      0.045,  # inward lunge distance, as a fraction of card width
	"pull_freq_mult": 0.7,    # tug tempo relative to wobble_freq (one coherent motion, just under the tilt)
}

const LINK := {
	# Motes leave a point on one card's orbit ring, arc across the gap, and merge onto the other
	# card's ring (fading in/out at the rings) — a seamless orbit-to-orbit transfer, never the centre.
	# Dense/large enough to read across the WIDE gap of the modal/panel (where a card-width sits
	# between the pair), not just the tight overlap of a drag — one config for every context.
	"count":        14,    # number of motes flowing between the two cards

	# Where on each ring motes enter/leave, and how curved the crossing is
	"spread":        1.3,    # radians of ring (each side of the facing point) motes fan across
	"bow":           0.18,   # arc curvature, as a fraction of the gap length (0 = straight)
	"end_fade":      0.22,   # fraction of the trip spent fading in (at source ring) / out (at sink ring)

	# Serpentine wobble — a travelling sine weave layered on the bow so motes oscillate side-to-side
	# as they cross (smooth, organic motion). An envelope keeps it zero at both rings. Per-mote
	# random freq/phase make every mote weave differently without looking like raw jitter.
	"wobble_amp_min":  0.04,   # peak side-sway, as a fraction of the gap length
	"wobble_amp_max":  0.13,
	"wobble_freq_min": 1.5,    # side-to-side cycles packed along the crossing (spatial)
	"wobble_freq_max": 3.0,
	"wobble_speed":    2.6,    # how fast the weave scrolls in time (rad/s) — gives it life

	# Travel
	"speed_min":     0.5,    # crossing speed (trips/sec)
	"speed_max":     1.1,

	# Per-mote dot
	"size_min":      0.9,
	"size_max":      2.2,
	"alpha_base":    0.75,
	"alpha_amp":     0.2,
	"alpha_min":     0.45,
	"alpha_max":     1.0,
	"white_chance":  0.4,
	"flick_min":     0.5,
	"flick_max":     1.2,
}
