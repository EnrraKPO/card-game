class_name VFXEffectShieldHit
extends VFXEffect


# Span: the badge glint's snap — no card drain follows, so the absorb reads fast.
func _init() -> void:
	span = 0.26


func play() -> void:
	if _event.target == null:
		queue_free(); return
	# A shield absorb is NOT a wound: react on the SHIELD BADGE only, leaving the card "protected"
	# (react_card = false skips the whole-card grey drain/tremble). The badge pops to pull the eye,
	# with a loss glint + the absorbed amount so it reads as "the shield took the blow".
	if _event.target.has_method("pulse_stat"):
		_event.target.pulse_stat("shield", true)   # flare — the shield springs up to block
	_stat_glint("shield", Color(0.4, 0.75, 1.0), false, false)
	_float_label("-%d" % _event.amount, Color(0.35, 0.75, 1.0), "shield")
	queue_free()
