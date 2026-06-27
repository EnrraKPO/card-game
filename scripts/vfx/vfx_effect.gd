class_name VFXEffect
extends Node

var _event: VFXEvent
var _root:  Node


func setup(event: VFXEvent, root: Node) -> void:
	_event = event
	_root  = root


# Override in subclasses. May use `await` internally to block the caller.
func play() -> void:
	queue_free()


# ── Shared helpers ─────────────────────────────────────────────────────────────

const LABEL_LIFE    := 0.95   # total time a number is on screen
const LABEL_RISE    := 42.0   # px it drifts upward over its life
const STACK_SPACING := 24.0   # vertical gap between numbers stacked on the same stat

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
	lbl.text     = text
	lbl.modulate = color
	# Big, with a fat dark outline so the number reads over any card art, and a high z so it sits
	# above every other VFX layer.
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("outline_size", 7)
	lbl.z_index = 60
	var anchor: Vector2 = card.stat_anchor(anchor_attr) if card.has_method("stat_anchor") \
		else card.global_position + card.size * 0.5
	# Start just above the badge (offset left to roughly centre a 1-2 digit number), stacked rows
	# climbing higher; then rise further from there.
	var base_pos := anchor + Vector2(-14.0, -26.0 - slot * STACK_SPACING)
	lbl.position = base_pos
	root.add_child(lbl)

	# ONE continuous, decelerating rise — no mid-animation freeze. Opacity (not motion) is staged:
	# solid for the first half so it reads, then fades over the second half.
	var rise := root.create_tween()
	rise.tween_property(lbl, "position:y", base_pos.y - LABEL_RISE, LABEL_LIFE).set_ease(Tween.EASE_OUT)

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
	glint.global_position = anchor - glint.size * 0.5
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
	var now := Time.get_ticks_msec()
	if card.has_meta("vfx_drain_until") and int(card.get_meta("vfx_drain_until")) > now:
		return
	card.set_meta("vfx_drain_until", now + 380)

	# Grey wash, sized to the card, above the art but below the ring/number layers.
	var wash := ColorRect.new()
	wash.color = Color(0.55, 0.55, 0.6, 0.0)
	wash.size = card.size
	wash.global_position = card.global_position
	wash.z_index = 16
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(wash)
	var wt := _root.create_tween()
	wt.tween_property(wash, "color:a", 0.5, 0.10).set_ease(Tween.EASE_OUT)
	wt.tween_property(wash, "color:a", 0.0, 0.28)
	wt.tween_callback(wash.queue_free)

	# 2D jitter back to origin. Bound to the card so it auto-cancels if the card is freed mid-shake.
	var origin := card.position
	var amp := 4.0
	var step := 0.035
	var st := card.create_tween()
	st.tween_property(card, "position", origin + Vector2(amp, -amp * 0.6), step)
	st.tween_property(card, "position", origin + Vector2(-amp, amp * 0.5), step)
	st.tween_property(card, "position", origin + Vector2(amp * 0.7, amp * 0.5), step)
	st.tween_property(card, "position", origin + Vector2(-amp * 0.6, -amp * 0.4), step)
	st.tween_property(card, "position", origin, step)
