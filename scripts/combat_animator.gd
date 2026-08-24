class_name CombatAnimator
extends Node

# Card motion choreography, salvaged from the pre-swap tree: attacker ghosts and the
# lunge/rebound/retreat cycle, plus the impact shake. The old results walk
# (show_effect_results) did not come over — motion is driven by the presenter's beats now
# (docs/planning/RULINGS.html R13).

var _root: Node


func setup(root: Node) -> void:
	_root = root


func spawn_ghost(source: CardUI) -> CardUI:
	var ghost := CardUI.create(source.card_data)
	ghost.z_index             = 20
	ghost.mouse_filter        = Control.MOUSE_FILTER_IGNORE
	ghost.custom_minimum_size = source.size
	_root.add_child(ghost)
	ghost.size = source.size
	ghost.global_position = source.global_position
	return ghost


func shake_card(card: CardUI) -> void:
	if card == null:
		return
	var origin := Vfx.begin_displace(card)   # one mover per card — see Vfx's displacement section
	var d      := 6.0
	var t      := 0.04
	var tw     := create_tween()
	tw.tween_property(card, "position", origin + Vector2(d,        0), t)
	tw.tween_property(card, "position", origin + Vector2(-d,       0), t)
	tw.tween_property(card, "position", origin + Vector2(d * 0.5,  0), t)
	tw.tween_property(card, "position", origin + Vector2(-d * 0.5, 0), t)
	tw.tween_property(card, "position", origin,                        t)
	Vfx.hold_displace(card, tw)
	await tw.finished


# The impact shake's timid sibling: a long, gentle, decaying shiver — a card losing its
# nerve rather than taking a hit (the surrender beat). Not awaited by design: it runs
# UNDER whatever the card is saying.
func tremble_card(card: CardUI, secs: float = 1.6) -> void:
	if card == null:
		return
	var origin := Vfx.begin_displace(card)   # one mover per card — see Vfx's displacement section
	var cycles := maxi(4, int(secs / 0.11))
	var tw := create_tween()
	for i in cycles:
		var fade := 1.0 - float(i) / float(cycles)
		var d := 2.5 * fade
		tw.tween_property(card, "position",
				origin + Vector2(d if i % 2 == 0 else -d, 0.0), 0.055)
	tw.tween_property(card, "position", origin, 0.055)
	Vfx.hold_displace(card, tw)


# Accelerate INTO the target (EASE_IN peaks at contact) so the strike is fastest at the
# moment of impact — the rebound picks the motion up from there without a pause.
func play_lunge(ghost: CardUI, target_pos: Vector2) -> void:
	var tw := create_tween()
	tw.set_ease(Tween.EASE_IN)
	tw.set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "global_position", target_pos, 0.18)
	await tw.finished


# Snappy recoil from the impact overshoot back to the attack position beside the target.
# EASE_OUT leaves the overshoot fast (the bounce) and TRANS_BACK springs a hair past the
# rest spot before settling. Chained straight off the lunge with no pause, so the
# overshoot reads as one motion.
func play_rebound(ghost: CardUI, rest_pos: Vector2) -> void:
	var tw := create_tween()
	tw.set_ease(Tween.EASE_OUT)
	tw.set_trans(Tween.TRANS_BACK)
	tw.tween_property(ghost, "global_position", rest_pos, 0.14)
	await tw.finished


# Glide back home from the attack position. STARTS the retreat and hands back its tween
# rather than awaiting it: the attacker leaves the moment it has connected, and the
# target's suffering (damage numbers, triggered glints, deaths) plays out WHILE it travels
# home. The caller awaits the returned tween once it also needs the ghost gone.
const RETREAT_DUR := 0.2   # the withdrawal's span — what its handoff is computed from

func start_retreat(ghost: CardUI, home_pos: Vector2) -> Tween:
	var tw := create_tween()
	tw.set_ease(Tween.EASE_OUT)
	tw.set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "global_position", home_pos, RETREAT_DUR)
	return tw
