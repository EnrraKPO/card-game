class_name VFXEffectSourceGlint
extends VFXEffect

# Played on the card whose triggered ability just fired — the "this one caused it" cue, shown
# once before the effect lands on its targets. The signature is an expanding halo that frames the
# whole card and blooms OUTWARD (distinct from the target reticle, which snaps inward, and from
# the gold card_placed flash, which only tints). A small scale pop sells the "charge up".

const HALO_GROW := 1.16
const HALO_DUR  := 0.2
const GLINT_COLOR := Color(1.0, 0.95, 0.7)   # warm white-gold, ability-agnostic for now


func play() -> void:
	var card := _event.target
	if card == null or not is_instance_valid(card):
		queue_free(); return

	# Outward halo: a rounded frame the size of the card that grows and fades. Lives on _root so it
	# outlives the card if the source dies (e.g. a deathrattle) mid-bloom.
	var halo := Panel.new()
	halo.size = card.size
	halo.custom_minimum_size = halo.size
	halo.z_index = 14
	halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	halo.pivot_offset = halo.size * 0.5
	halo.global_position = card.global_position
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(GLINT_COLOR, 0.0)
	sb.set_corner_radius_all(14)
	# Keep it a quiet outline, not a flaring aura: thin border, small faint shadow. This only says
	# "this card fired" for a beat — the eye should move straight on to what changed on the targets.
	sb.border_color = Color(GLINT_COLOR, 0.8)
	sb.set_border_width_all(3)
	sb.shadow_color = Color(GLINT_COLOR, 0.28)
	sb.shadow_size = 5
	sb.anti_aliasing = true
	halo.add_theme_stylebox_override("panel", sb)
	_root.add_child(halo)
	var ht := _root.create_tween()
	ht.set_parallel(true)
	ht.tween_property(halo, "scale", Vector2(HALO_GROW, HALO_GROW), HALO_DUR).set_ease(Tween.EASE_OUT)
	ht.tween_property(halo, "modulate:a", 0.0, HALO_DUR)
	ht.chain().tween_callback(halo.queue_free)

	# Brief scale pop on the card itself, returned to ONE so it never leaves the unit mis-sized.
	card.pivot_offset = card.size * 0.5
	var pt := card.create_tween()
	pt.set_trans(Tween.TRANS_QUAD)
	pt.tween_property(card, "scale", Vector2(1.08, 1.08), 0.10).set_ease(Tween.EASE_OUT)
	pt.tween_property(card, "scale", Vector2.ONE, 0.14).set_ease(Tween.EASE_IN)

	queue_free()
