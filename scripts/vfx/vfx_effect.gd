class_name VFXEffect
extends Node

var _event: VFXEvent
var _root:  Node

# How long this look actually PLAYS, in seconds — its span, not its handoff. The sequencer starts
# the next beat partway through it (span × (1 - overlap); see Vfx.handoff), so the tail of this cue
# runs under the head of the next one instead of the sequence waiting in dead air.
#
# Set it in _init() to the look's COMMUNICATIVE core — the part that carries the meaning — NOT the
# length of its longest tween. Almost every look is core + TAIL, and the tail is meant to be played
# over: a floating number drifts away, a wash fades, a reticle dissolves, a crit rings on. Sizing a
# span to the full tween is the classic mistake — it makes the sequence stall while finished-looking
# animations run out their fades.
#
# The sharpest case is a POINTER cue (the source glint, the target reticle): it exists only to move
# the eye, and it has done that the instant it snaps. Those spans are barely over their snap-in
# time, so the hit they point at lands almost on top of them.
#
# span = 0.0 means ATOMIC: this look's completion IS its beat, and the sequencer awaits play() to
# the last frame. Correct only when finishing is load-bearing — a projectile whose landing is the
# impact, a death fade whose card is removed the instant it ends.
var span: float = 0.0


func setup(event: VFXEvent, root: Node) -> void:
	_event = event
	_root  = root


# Override in subclasses. May use `await` internally to block the caller (see `span`: an atomic
# look is awaited to completion; a spanned look plays on in the background past its handoff).
func play() -> void:
	queue_free()


# ── Shared helpers ─────────────────────────────────────────────────────────────

const LABEL_LIFE    := 0.95   # total time a number is on screen
const LABEL_RISE    := 42.0   # px it drifts upward over its life
const STACK_SPACING := 24.0   # vertical gap between numbers stacked on the same stat
const NUMBER_FONT := preload("res://assets/fontd/Baloo_2/static/Baloo2-ExtraBold.ttf")

# Pops a combat number anchored to the stat it changes (`anchor_attr`: "health", "shield", "attack",
# "speed", "cost"; "" = card centre). Position is the primary cue — a red number over the HP badge
# reads as HP loss without parsing text — so the callers pass just a signed value, no stat suffix.
func _float_label(text: String, color: Color, anchor_attr: String = "") -> void:
	var card := _event.target
	if card == null or not is_instance_valid(card):
		return
	var root := _root
	# Per-stat rows: numbers on different stats sit at different badges already, so only same-stat
	# pile-ups (two HP hits) need staggering.
	var slot := _reserve_label_slot(root, "%d:%s" % [card.get_instance_id(), anchor_attr])

	var lbl := Label.new()
	lbl.text = text
	# `color` sets the actual font color directly — NOT via modulate, which multiplies against the
	# theme's default Label color. That default is now a dark warm brown (the light re-theme), so
	# modulate-tinting used to crush every number toward near-black regardless of `color`. modulate
	# itself stays white and is only ever used below for the alpha fade-out, never for tint.
	# Big, chunky (matches the button font), with a fat dark outline so the number reads over any
	# card art, and a high z so it sits above every other VFX layer.
	lbl.add_theme_font_override("font", NUMBER_FONT)
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("outline_size", 7)
	lbl.z_index = 60
	var anchor: Vector2 = card.stat_anchor(anchor_attr) if card.has_method("stat_anchor") \
		else card.global_position + card.size * 0.5
	# Start just above the badge (offset left to roughly centre a 1-2 digit number), stacked rows
	# climbing higher; then rise further from there. `anchor` is GLOBAL, so position via
	# global_position and only after add_child (before parenting the setter writes plain
	# `position`, which offsets the number by root's global offset — the header above combat).
	var base_pos := anchor + Vector2(-14.0, -26.0 - slot * STACK_SPACING)
	root.add_child(lbl)
	lbl.global_position = base_pos

	# ONE continuous, decelerating rise — no mid-animation freeze. Opacity (not motion) is staged:
	# solid for the first half so it reads, then fades over the second half. The rise target is in
	# the label's LOCAL space (position:y), relative to where it just landed.
	var rise := root.create_tween()
	rise.tween_property(lbl, "position:y", lbl.position.y - LABEL_RISE, LABEL_LIFE).set_ease(Tween.EASE_OUT)

	var fade := root.create_tween()
	fade.tween_interval(LABEL_LIFE * 0.5)
	fade.tween_property(lbl, "modulate:a", 0.0, LABEL_LIFE * 0.5)
	fade.tween_callback(lbl.queue_free)   # bound to the label (alive), not this transient effect


# Hands a number its own row (keyed per card+stat) so simultaneous same-stat labels don't pile on
# one pixel. Time-based and release-free: each row carries an expiry, and the lowest already-expired
# row is reused — no teardown callback to fire from a freed effect. Lives on the combat root's
# metadata so all the transient effect nodes share one registry.
static func _reserve_label_slot(root: Node, key: String) -> int:
	var now := Time.get_ticks_msec()
	var stacks: Dictionary = root.get_meta("vfx_label_stacks", {})
	var rows: Array = stacks.get(key, [])   # row index -> ms timestamp the row frees up
	var idx := -1
	for i in rows.size():
		if int(rows[i]) <= now:
			idx = i
			break
	if idx == -1:
		idx = rows.size()
		rows.append(0)
	rows[idx] = now + int(LABEL_LIFE * 1000.0)
	stacks[key] = rows
	root.set_meta("vfx_label_stacks", stacks)
	return idx


func _flash(flash_color: Color, duration: float = 0.35) -> void:
	if _event.target == null or not is_instance_valid(_event.target):
		return
	var tw := _event.target.create_tween()
	tw.tween_property(_event.target, "modulate", flash_color, duration * 0.25)
	tw.tween_property(_event.target, "modulate", Color.WHITE, duration * 0.75)


# A focused pulse on a single stat badge — the eye-director. Polarity drives a shared motion
# language: a GAIN (`positive`) blooms outward as a soft filled disc; a LOSS is a hollow ring that
# snaps inward. Coloured by the effect so the stat's own identity carries through. Anchored to the
# badge via CardUI.stat_anchor (falls back to card centre). `react_card` gates the whole-card drain
# that a loss normally triggers — pass false when the badge alone should react (a shield that
# absorbed a hit isn't a wound, so the card stays "protected").
func _stat_glint(anchor_attr: String, color: Color, positive: bool, react_card: bool = true) -> void:
	var card := _event.target
	if _root == null or card == null or not is_instance_valid(card):
		return
	var anchor: Vector2 = card.stat_anchor(anchor_attr) if card.has_method("stat_anchor") \
		else card.global_position + card.size * 0.5
	var d := 44.0
	var glint := Panel.new()
	glint.size = Vector2(d, d)
	glint.custom_minimum_size = glint.size
	glint.z_index = 17
	glint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glint.pivot_offset = glint.size * 0.5
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(int(d * 0.5))   # circular
	sb.anti_aliasing = true
	if positive:
		sb.bg_color     = Color(color, 0.45)
		sb.shadow_color = Color(color, 0.7)
		sb.shadow_size  = 12
	else:
		# Understated ring (the real signal is the card drain + tremble below): faint, thin.
		sb.bg_color     = Color(color, 0.0)
		sb.border_color = Color(color, 0.5)
		sb.set_border_width_all(2)
	glint.add_theme_stylebox_override("panel", sb)
	_root.add_child(glint)
	glint.global_position = anchor - glint.size * 0.5   # AFTER add_child — see _float_label
	var tw := _root.create_tween()
	tw.set_parallel(true)
	if positive:
		glint.scale = Vector2(0.5, 0.5)
		tw.tween_property(glint, "scale", Vector2(1.7, 1.7), 0.36).set_ease(Tween.EASE_OUT)
		tw.tween_property(glint, "modulate:a", 0.0, 0.34)
	else:
		glint.scale = Vector2(1.5, 1.5)
		tw.tween_property(glint, "scale", Vector2(0.9, 0.9), 0.30).set_ease(Tween.EASE_IN)
		# Desaturate while fading (toward grey), not a plain fade — reinforces the "draining" read.
		tw.tween_property(glint, "modulate", Color(0.6, 0.6, 0.6, 0.0), 0.34)
		if react_card:
			_drain_card(card)
	tw.chain().tween_callback(glint.queue_free)


# The negative-event card reaction: a brief grey wash (mixes the card toward grey → lower apparent
# saturation) plus a trembling vibration — "this unit was hit / weakened". Guarded by a per-card
# timestamp so simultaneous negative glints (a strike's shield AND health loss) fire it once.
func _drain_card(card: Control) -> void:
	if _root == null or card == null or not is_instance_valid(card):
		return
	# A louder cue is already the card's answer to this blow (a crit stagger) — don't talk over it.
	# See Vfx.claim_reaction: the drain's wash would fight the crit's hot flash, and its tremble
	# would cancel the stagger outright through the displacement claim.
	if Vfx.reaction_claimed(card):
		return
	var now := Time.get_ticks_msec()
	if card.has_meta("vfx_drain_until") and int(card.get_meta("vfx_drain_until")) > now:
		return
	card.set_meta("vfx_drain_until", now + 380)

	# Grey wash, sized to the card, above the art but below the ring/number layers.
	var wash := ColorRect.new()
	wash.color = Color(0.55, 0.55, 0.6, 0.0)
	wash.size = card.size
	wash.z_index = 16
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(wash)
	wash.global_position = card.global_position   # AFTER add_child — see _float_label
	var wt := _root.create_tween()
	wt.tween_property(wash, "color:a", 0.5, 0.10).set_ease(Tween.EASE_OUT)
	wt.tween_property(wash, "color:a", 0.0, 0.28)
	wt.tween_callback(wash.queue_free)

	# 2D jitter back to origin. Bound to the card so it auto-cancels if the card is freed mid-shake,
	# and claimed through Vfx so it can't run alongside another displacement (an impact shake, a
	# dodge, a crit stagger) — see the displacement section in Vfx for why that matters.
	var origin := Vfx.begin_displace(card)
	var amp := 4.0
	var step := 0.035
	var st := card.create_tween()
	st.tween_property(card, "position", origin + Vector2(amp, -amp * 0.6), step)
	st.tween_property(card, "position", origin + Vector2(-amp, amp * 0.5), step)
	st.tween_property(card, "position", origin + Vector2(amp * 0.7, amp * 0.5), step)
	st.tween_property(card, "position", origin + Vector2(-amp * 0.6, -amp * 0.4), step)
	st.tween_property(card, "position", origin, step)
	Vfx.hold_displace(card, st)
