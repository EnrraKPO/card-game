class_name VFXEffectCrit
extends VFXEffect

# Played when an attack lands as a CRITICAL (the speed-driven damage spike in Resolver._submit).
# Unlike a dodge or a miss, real damage still lands — so this cue sits ALONGSIDE the normal
# shield/health damage numbers, never replacing them. It has to feel like it HURTS: the victim
# flashes hot, gets punched (a quick squash), shakes violently and emits a shockwave ring, with
# a "CRITICAL!" label over it all.
#
# The whole cue is DAMAGE-SCALED: VFXEvent.amount carries the hit's total landed damage, and
# severity = damage / the victim's max health drives every knob (shake amplitude, punch depth,
# ring size, label size) — a graze-crit stings, a near-lethal one erupts. A floor keeps even
# the smallest crit clearly above an ordinary hit.
#
# The attacker-side half of the cue (the Speed badge glint — speed is what drove the crit)
# fires at the combat call site, since this event only knows the card being hit.

const CRIT_COLOR := Color(1.0, 0.42, 0.24)   # hot red-orange — escalation, distinct from the
											 # cyan of Dodge and the grey of Miss
const SEV_FLOOR := 0.35                      # minimum intensity: every crit reads as one


func play() -> void:
	var card := _event.target
	if card == null or not is_instance_valid(card):
		queue_free(); return
	var sev := _severity(card)
	_impact_flash(card, sev)
	_stagger(card, sev)
	_shockwave(card, sev)
	_crit_label(card, sev)
	queue_free()


# Damage relative to the victim's max health, floored so a small crit still lands visually and
# ceilinged at 1 (overkill can't grow past "eruption"). A missing instance/amount falls back to
# the floor — the cue still plays, just at minimum strength.
func _severity(card: Control) -> float:
	var ui := card as CardUI
	if _event.amount <= 0 or ui == null or ui.card_instance == null:
		return SEV_FLOOR
	var max_hp := maxf(1.0, float(ui.card_instance.get_attribute("max_health")))
	return clampf(float(_event.amount) / max_hp, SEV_FLOOR, 1.0)


# The blow itself: a DIRECTIONAL STAGGER. Squash-and-stretch was tried and rejected — a
# symmetric deformation about the card's own centre has no direction, so it never read as
# a blow coming FROM somewhere (user). Instead the card is knocked bodily AWAY from the
# attacker — displaced sideways with a slight lift AND tilted off its base (pivot at the
# bottom centre, rocking back on its heels) — then springs back upright.
#
# THE IMPACT IS NOT ANIMATED: the card is already displaced + tilted the frame the cue
# starts (easing into an impact drains its violence). All the animation time goes to the
# recovery — a held beat, then a long elastic ring-out that wobbles the card back through
# diminishing counter-leans ("baaahm", not "bam-done"). Kick distance and tilt scale with
# severity. Hit direction follows board sides, same convention as the dodge sidestep:
# player units (owner 0) are struck from the right, enemies from the left.
func _stagger(card: Control, sev: float) -> void:
	var origin := card.position
	var prev_pivot := card.pivot_offset
	card.pivot_offset = Vector2(card.size.x * 0.5, card.size.y)   # rock about the base
	var dir := -1.0 if _owner_of(card) == 0 else 1.0
	var kick := 16.0 + 22.0 * sev
	var tilt := 6.0 + 8.0 * sev
	# The blow has ALREADY landed: knocked away and leaning off vertical at frame zero.
	card.position = origin + Vector2(dir * kick, -kick * 0.12)
	card.rotation_degrees = dir * tilt
	var tw := card.create_tween()
	tw.tween_interval(0.08 + 0.08 * sev)   # a beat off-balance — hard hits hang there longer
	tw.tween_property(card, "position", origin, 0.85) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(card, "rotation_degrees", 0.0, 0.85) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(card):
			card.pivot_offset = prev_pivot)


# The owning side of the board card, read off its CardInstance; defaults to player (0) so a
# card without one still staggers a sensible way. (Same helper shape as VFXEffectDodge's.)
func _owner_of(card: Control) -> int:
	var ui := card as CardUI
	if ui != null and ui.card_instance != null:
		return ui.card_instance.owner
	return 0


# The hot wash: SLAMS to full red-orange instantly (no ease-in — same principle as the punch)
# and burns back down to normal, lingering longer on harder hits.
func _impact_flash(card: Control, sev: float) -> void:
	card.modulate = Color(1.0, 0.5, 0.35)
	var tw := card.create_tween()
	tw.tween_property(card, "modulate", Color.WHITE, 0.70 + 0.50 * sev) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# A hot shockwave ring erupting from the card's centre — the "impact radiates outward" read,
# slowed so it visibly travels. Final diameter and border weight scale with severity; hard
# hits (sev > 0.5) emit a delayed second AFTERSHOCK ring, so the blow keeps producing
# consequences after the first beat.
func _shockwave(card: Control, sev: float) -> void:
	if _root == null:
		return
	_spawn_ring(_root, card, sev)
	if sev > 0.5:
		# The aftershock rides a root-bound timer (NOT this effect node — it frees at the end
		# of play(), long before the delay elapses) and re-checks the card is still alive.
		var root := _root
		var t := _root.create_tween()
		t.tween_interval(0.22)
		t.tween_callback(func() -> void:
			if is_instance_valid(card):
				VFXEffectCrit._spawn_ring(root, card, sev * 0.6))


# Static so the delayed aftershock can spawn one after this effect node is gone.
static func _spawn_ring(root: Node, card: Control, sev: float) -> void:
	var d := 60.0
	var ring := Panel.new()
	ring.size = Vector2(d, d)
	ring.custom_minimum_size = ring.size
	ring.z_index = 55
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.pivot_offset = ring.size * 0.5
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(int(d * 0.5))
	sb.anti_aliasing = true
	sb.bg_color = Color(CRIT_COLOR, 0.0)
	sb.border_color = Color(CRIT_COLOR, 0.85)
	sb.set_border_width_all(3 + int(3.0 * sev))
	ring.add_theme_stylebox_override("panel", sb)
	root.add_child(ring)
	var center: Vector2 = card.global_position + card.size * 0.5
	ring.global_position = center - ring.size * 0.5   # AFTER add_child — see _float_label
	ring.scale = Vector2(0.25, 0.25)
	var grow := 1.4 + 1.6 * sev
	var tw := root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(grow, grow), 0.55).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "modulate:a", 0.0, 0.60).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(ring.queue_free)


# The "CRITICAL!" label — same skeleton as the shared _float_label, but with a severity-scaled
# font size (the shared helper is fixed at 30; a crit's word IS the intensity meter) and a
# slam-in: it lands oversized and snaps to rest before the ordinary rise-and-fade.
func _crit_label(card: Control, sev: float) -> void:
	if _root == null:
		return
	var size := int(round(28.0 + 18.0 * sev))
	var lbl := Label.new()
	lbl.text = "CRITICAL!"
	lbl.add_theme_font_override("font", NUMBER_FONT)
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", CRIT_COLOR)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("outline_size", 8)
	lbl.z_index = 61   # above the damage numbers (60) — the headline over the arithmetic
	var center: Vector2 = card.global_position + card.size * 0.5
	_root.add_child(lbl)
	# Centre horizontally on the card, sit above its middle. reset_size() snaps the label to its
	# content synchronously (no frame wait — this effect node frees at the end of play()).
	lbl.reset_size()
	lbl.pivot_offset = lbl.size * 0.5
	lbl.global_position = center - Vector2(lbl.size.x * 0.5, lbl.size.y * 0.5 + 34.0)

	# Slam: oversized → rest (EASE_IN so it accelerates INTO place, a stamp not a bloom).
	lbl.scale = Vector2(1.6, 1.6)
	var slam := _root.create_tween()
	slam.tween_property(lbl, "scale", Vector2.ONE, 0.10).set_ease(Tween.EASE_IN)

	# Then the familiar rise-and-fade, clearly longer than a number — the word stays on
	# screen through the whole elastic ring-out.
	var life := LABEL_LIFE * 1.5
	var rise := _root.create_tween()
	rise.tween_property(lbl, "position:y", lbl.position.y - LABEL_RISE, life).set_ease(Tween.EASE_OUT)
	var fade := _root.create_tween()
	fade.tween_interval(life * 0.55)
	fade.tween_property(lbl, "modulate:a", 0.0, life * 0.45)
	fade.tween_callback(lbl.queue_free)
