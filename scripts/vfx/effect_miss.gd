class_name VFXEffectMiss
extends VFXEffect

# Played when an attack is negated (Blind): a pale "Miss" label floats off the would-be victim, in
# place of the usual damage number — so a dodged strike reads at a glance.


# Span: no motion of its own — long enough to READ the word, not to watch it drift away.
func _init() -> void:
	span = 0.30


func play() -> void:
	if _event.target == null or not is_instance_valid(_event.target):
		queue_free(); return
	_float_label(Loc.t("combat.miss_label"), Color(0.82, 0.84, 0.92), "")
	queue_free()
