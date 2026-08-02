class_name UnitSlideFx
extends RefCounted

# THE ARRIVAL of a unit at a new slot: it travels there from the one it left.
#
# A repositioning enemy used to change slots between frames. The board was right afterwards and the
# player had no way to know how it got that way — with several units on the field, a unit that
# teleports is indistinguishable from a unit that was replaced, and the CPU's whole reason for
# moving (getting to a lane, backing off a threat) is lost. The path IS the information.
#
# ── Why it is written as a correction, not a journey ────────────────────────────────
# The card is REPARENTED into its destination slot before this runs — the layout has already put it
# where it now belongs, which is the only place it can be left standing. So the slide does not carry
# the card to its destination; it puts the card back where it came from and then lets the layout's
# answer win over `duration`. That way nothing downstream ever has to know an animation is playing:
# the card's resting position is correct from the first frame, and the slide is a transient
# displacement over it — the same shape as every other cue that moves a widget in place.
#
# It takes the displacement claim (Vfx.begin_displace) for exactly that reason. A unit that is shoved
# while it is moving, or moved twice in one turn, must not leave two tweens fighting over one
# `position` — the claim cancels the older mover and hands the true rest to the new one.
#
# Registered as the `unit_move_slide` entry's custom renderer, so it is played by id like anything
# else: Vfx.play("unit_move_slide", card, {"from": <global position before the move>}).

const ENTRY := "unit_move_slide"

const DEF_DUR := 0.26
# Enough to clear the board's own furniture, and the same lift the selection Highlight takes so a
# travelling card and a picked one can never disagree about which of them is on top.
const Z_LIFT := HighlightFx.Z_LIFT


static func play(vd: VFXData, target: Control, opts: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	if not opts.has("from"):
		return
	var from: Vector2 = opts["from"]
	# The destination slot lays its new occupant out on the NEXT frame; measured before that, the
	# card is still standing at whatever position its old slot gave it and the offset comes out zero.
	await target.get_tree().process_frame
	if not is_instance_valid(target) or not target.is_inside_tree():
		return

	var rest := Vfx.begin_displace(target)   # exclusive — see Vfx's displacement section
	# Global travel, expressed in the coordinates the card's `position` actually speaks: the two
	# slots are siblings today, but a card whose parent is scaled (a smaller board, a zoomed view)
	# would slide by the wrong distance if the global delta were used raw.
	var parent := target.get_parent() as Control
	var offset := target.global_position - from
	if parent != null:
		offset = parent.get_global_transform().affine_inverse().basis_xform(offset)
	if offset.is_zero_approx():
		return
	var dur := Vfx.paced(maxf(0.05, vd.num_param("duration", DEF_DUR)), vd)

	# A card in transit is standing between slots, and every slot it crosses is a sibling drawn after
	# it — without the lift the unit slides UNDERNEATH the board, appearing and disappearing behind
	# empty squares on its way. Lifted only for the crossing: a card that kept it would sit
	# permanently over its neighbours for no reason the player could see.
	var z_rest := target.z_index
	target.z_index = z_rest + Z_LIFT

	target.position = rest - offset
	var tw := target.create_tween()
	# EASE_OUT: a unit crossing the board sets off decisively and settles into its slot, rather than
	# creeping away and slamming down. The card is the thing being watched, so the arrival is the
	# half that has to be readable.
	tw.tween_property(target, "position", rest, dur) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	Vfx.hold_displace(target, tw)

	# Waited out on a TIMER, not on the tween: a mover that is cancelled mid-flight never emits
	# `finished`, and the card would keep the draw-order lift for the rest of the fight (see
	# Vfx.holds_displace). The timer cannot be cancelled, so the lift always comes back off.
	await target.get_tree().create_timer(dur).timeout
	if not is_instance_valid(target):
		return
	target.z_index = z_rest
	# The transform is only ours to finish if nothing has claimed the card since — a newer mover has
	# already put it back where it belongs and is moving it from there.
	if Vfx.holds_displace(target, tw):
		target.position = rest
