class_name ScreenGrowFx
extends RefCounted

# An ARRIVAL cue: the screen swells into existence from nothing, at the centre of the viewport.
#
# Every navigation already ends in one hook — Shell.mount plays an arrival entry on the freshly
# mounted content — and this is a second entry that hook can be pointed at, per navigation:
#
#   Nav.goto("res://scenes/reward_screen.tscn", "screen_grow_in")
#
# Its reason for existing is the treasure chest: the orb the chest releases flies to the middle
# of the screen (RewardOrbFx) and the reward screen grows out of exactly that spot, so opening
# the chest and arriving at the rewards are one motion instead of a cut. Any other screen that
# wants the same entrance names the same id — that is as general as this needs to be for now.
#
# The chrome around the content (the persistent header/footer) is deliberately NOT scaled: it
# belongs to the Shell, not to the arriving screen, and yanking it about would contradict the
# whole point of it being persistent. It fades in over the same span instead.

const DEF_DUR := 0.42


static func play(vd: VFXData, target: Control, _opts: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	# One frame of patience: a just-mounted screen has a zero rect until its containers lay it
	# out, and scaling about a pivot of (0,0) would grow it out of the top-left corner.
	if target.get_global_rect().size == Vector2.ZERO:
		await target.get_tree().process_frame
		if not is_instance_valid(target) or not target.is_inside_tree():
			return
	var dur := Vfx.paced(maxf(0.05, vd.num_param("duration", DEF_DUR)))
	target.pivot_offset = target.size * 0.5
	target.scale = Vector2.ZERO
	target.modulate.a = 0.0
	var tw := target.create_tween()
	tw.tween_property(target, "scale", Vector2.ONE, dur) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(target, "modulate:a", 1.0, dur * 0.55)
	await tw.finished
	if is_instance_valid(target):
		target.scale = Vector2.ONE   # exact, so nothing downstream measures a rounding error
